import SwiftUI
import UniformTypeIdentifiers

/// Roblox-style hierarchy: a Workspace holding every part, with scripts nested
/// inside the part they belong to, plus a Script Service for unattached scripts.
struct ExplorerView: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession

    private var controller: ViewportController { session.viewport }

    @State private var filter: String = ""
    @State private var renamingID: UUID?
    @State private var renameText: String = ""
    @State private var workspaceExpanded = true
    @State private var serviceExpanded = true
    @State private var shadersExpanded = true
    @State private var screenExpanded = true
    @State private var starterExpanded = true
    @State private var starterPackExpanded = true
    @State private var starterGuiExpanded = true
    @State private var assetsExpanded = true
    @State private var soundServiceExpanded = true
    @State private var animationsExpanded = true
    @State private var playerScriptsExpanded = true
    @State private var characterScriptsExpanded = true
    @State private var expandedParts: Set<UUID> = []

    private var looseScripts: [ScriptObject] {
        let scripts = model.scripts(parentID: nil)
        guard !filter.isEmpty else { return scripts }
        return scripts.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private func filteredShaders(_ kind: ShaderKind) -> [ShaderObject] {
        let shaders = model.shaders(kind: kind)
        guard !filter.isEmpty else { return shaders }
        return shaders.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var shaderTint: Color { Color(red: 0.55, green: 0.72, blue: 0.95) }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "Explorer", systemImage: "list.bullet.indent") {
                Menu {
                    ForEach(PartShape.allCases) { shape in
                        Button("Insert \(shape.displayName)") {
                            controller.insertPart(shape: shape, atScreenPoint: nil)
                        }
                    }
                    Divider()
                    Button("New Script") {
                        let parent = model.selection.count == 1 ? model.selection.first : nil
                        if let parent { expandedParts.insert(parent) }
                        session.openScript(model.addScript(parentID: parent))
                    }
                    Button("New Wren Script") {
                        let parent = model.selection.count == 1 ? model.selection.first : nil
                        if let parent { expandedParts.insert(parent) }
                        session.openScript(model.addScript(parentID: parent, language: .wren))
                    }
                    Button("New Shader") {
                        let id = model.addShader(kind: .surface)
                        if !model.selection.isEmpty {
                            model.assignShader(id, to: model.selection)
                        }
                        session.openShader(id)
                    }
                    Button("New Screen Effect") {
                        session.openShader(model.addShader(kind: .screen))
                    }
                    Button("New Model") {
                        if model.selection.isEmpty {
                            _ = model.makeGroup(kind: .model)
                        } else {
                            model.groupSelection(kind: .model)
                        }
                    }
                    Button("New Folder") {
                        if model.selection.isEmpty {
                            _ = model.makeGroup(kind: .folder)
                        } else {
                            model.groupSelection(kind: .folder)
                        }
                    }
                    Button("New Tool") { model.addTool() }
                    Button("Insert Rig") { controller.insertRig() }
                    Button("Import Picture, Sound or 3D Model…") { importAssets() }
                    Menu("New Light (in the selected part)") {
                        ForEach(PointLight.Kind.allCases) { kind in
                            Button(kind.rawValue) {
                                if let part = model.selection.first {
                                    expandedParts.insert(part); model.addLight(kind, to: part)
                                }
                            }
                        }
                    }
                    .disabled(model.selection.count != 1 || model.selection.first.flatMap(model.part(id:)) == nil)
                    Menu("New ParticleEmitter (in the selected part)") {
                        ForEach(ParticleEmitter.Preset.allCases) { preset in
                            Button(preset.rawValue) {
                                if let part = model.selection.first.flatMap({ model.part(id: $0)?.id }) {
                                    expandedParts.insert(part)
                                    model.addEmitter(preset, to: part)
                                }
                            }
                        }
                    }
                    .disabled(model.selection.count != 1 || model.selection.first.flatMap(model.part(id:)) == nil)
                    Button("New Sound") {
                        let part = model.selection.count == 1 ? model.selection.first.flatMap { model.part(id: $0)?.id } : nil
                        if let part { expandedParts.insert(part) } else { soundServiceExpanded = true }
                        model.addSound(in: part)
                    }
                    Button("New ScreenGui") {
                        starterGuiExpanded = true
                        model.addGuiObject(.screenGui, in: nil)
                    }
                    Button("New Animation") {
                        model.addAnimation()
                        session.showDock(.animation)
                    }
                    Divider()
                    Button("New ModuleScript") {
                        session.openScript(model.addModuleScript())
                    }
                    Button("New RemoteEvent") { model.addDataObject(.remoteEvent) }
                    Divider()
                    Button("New StarterPlayer Script") {
                        playerScriptsExpanded = true
                        session.openScript(model.addScript(host: .starterPlayer))
                    }
                    Button("New StarterCharacter Script") {
                        characterScriptsExpanded = true
                        session.openScript(model.addScript(host: .starterCharacter))
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 22)
            }

            searchField

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    groupRow(title: "Workspace",
                             icon: "globe.americas.fill",
                             tint: Theme.accent,
                             count: model.parts.count,
                             expanded: $workspaceExpanded) {
                        model.selection = []
                        model.selectedScript = nil
                    }
                    .dropDestination(for: String.self) { items, _ in drop(items, onto: nil) }

                    if workspaceExpanded {
                        if !model.terrain.isEmpty {
                            // The Workspace's Terrain: the Terrain Editor edits it.
                            HStack(spacing: 6) {
                                Image(systemName: "mountain.2.fill").font(.system(size: 10))
                                    .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 0.4)).frame(width: 14)
                                Text("Terrain").font(.system(size: 12)).foregroundStyle(Theme.text)
                                Spacer()
                                Text("\(model.terrain.chunks.count)").font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(Theme.textDim)
                            }
                            .padding(.vertical, 3)
                            .padding(.leading, 28)
                            .padding(.trailing, 6)
                            .contentShape(Rectangle())
                            .onTapGesture { session.showDock(.terrain) }
                            .help("Edit it in the Terrain Editor (the dock's Terrain tab)")
                        }
                        let rows = treeRows
                        ForEach(rows, id: \.self) { row in
                            switch row {
                            case .node(.part(let id), let depth):
                                if let part = model.part(id: id) { partRow(part, depth: depth) }
                            case .gui(let id, let depth):
                                if let object = model.guiObject(id: id) {
                                    guiRow(object, depth: depth)
                                    if expandedParts.contains(id) { viewportChildRows(object, depth: depth) }
                                }
                            case .node(.group(let id), let depth):
                                if let group = model.group(id: id) { treeGroupRow(group, depth: depth) }
                            case .script(let id, let depth):
                                if let script = model.script(id: id) {
                                    scriptRow(script, indent: 26 + CGFloat(depth) * 14)
                                        .draggable(script.id.uuidString)
                                }
                            case .attachment(let id, let depth):
                                if let attachment = model.attachment(id: id) {
                                    fixtureRow(id: id, depth: depth, name: attachment.name, icon: "smallcircle.filled.circle",
                                               tint: Color(red: 0.55, green: 0.85, blue: 0.55),
                                               selected: model.selectedAttachment == id, detail: "") {
                                        model.selection = []
                                        model.selectedAttachment = id
                                        model.selectedConstraint = nil
                                    } delete: {
                                        model.commit("Deleted attachment") {
                                            model.attachments.removeAll { $0.id == id }
                                            model.pruneConstraints()
                                        }
                                    }
                                }
                            case .constraint(let id, let depth):
                                if let constraint = model.constraint(id: id) {
                                    fixtureRow(id: id, depth: depth, name: constraint.name,
                                               icon: constraint.kind.symbolName,
                                               tint: Color(red: 0.95, green: 0.75, blue: 0.45),
                                               selected: model.selectedConstraint == id,
                                               detail: constraint.enabled ? "" : "off") {
                                        model.selection = []
                                        model.selectedConstraint = id
                                        model.selectedAttachment = nil
                                    } delete: {
                                        model.deleteConstraint(id: id)
                                    }
                                }
                            case .sound(let id, let depth):
                                if let sound = model.sound(id: id) {
                                    soundRow(sound, depth: depth)
                                }
                            case .light(let id, let depth):
                                if let light = model.light(id) {
                                    fixtureRow(id: id, depth: depth, name: light.name, icon: "lightbulb.fill",
                                               tint: Color(vec: light.color), selected: model.selectedLight == id,
                                               detail: light.enabled ? "" : "off") {
                                        model.selectedLight = id
                                    } delete: { model.removeLight(id) }
                                }
                            case .emitter(let ref, let depth):
                                if let emitter = model.emitter(ref) {
                                    fixtureRow(id: ref.emitter, depth: depth, name: emitter.name, icon: "sparkles",
                                               tint: EmitterInspector.tint, selected: model.selectedEmitter == ref,
                                               detail: emitter.enabled ? "" : "off") {
                                        model.selection = []
                                        model.selectedScript = nil
                                        model.selectedEmitter = ref
                                    } delete: {
                                        model.removeEmitter(ref)
                                    }
                                }
                            case .data(let id, let depth):
                                if let object = model.dataObject(id: id) {
                                    fixtureRow(id: id, depth: depth, name: object.name, icon: object.className.symbolName,
                                               tint: StorageGroup.tint, selected: model.selectedDataObject == id,
                                               detail: object.className == .humanoid ? "\(Int(object.health)) hp"
                                                   : object.className.isValue ? DataObjectInspector.describe(object.value) : "") {
                                        model.selection = []
                                        model.selectedScript = nil
                                        model.selectDataObject(id)
                                    } delete: {
                                        model.removeDataObjects([id])
                                    }
                                }
                            }
                        }
                        if rows.isEmpty && (model.terrain.isEmpty || !filter.isEmpty) {
                            emptyNote(model.parts.isEmpty && model.groups.isEmpty ? "Workspace is empty" : "No matches")
                        }
                    }

                    groupRow(title: "Script Service",
                             icon: "curlybraces",
                             tint: Color(red: 0.62, green: 0.78, blue: 0.45),
                             count: model.scripts(parentID: nil).count,
                             expanded: $serviceExpanded) {
                        model.selection = []
                    }
                    .padding(.top, 4)

                    .contextMenu {
                        Button("New Script") { session.openScript(model.addScript()) }
                        Button("New ModuleScript") { session.openScript(model.addModuleScript(host: .scene)) }
                    }

                    if serviceExpanded {
                        ForEach(looseScripts) { script in
                            scriptRow(script, indent: 20)
                        }
                        if looseScripts.isEmpty {
                            emptyNote("No standalone scripts")
                        }
                    }

                    StorageGroup(model: model, session: session, place: .replicatedStorage)
                    StorageGroup(model: model, session: session, place: .serverStorage)

                    groupRow(title: "Shaders",
                             icon: "paintbrush.pointed.fill",
                             tint: shaderTint,
                             count: model.shaders(kind: .surface).count,
                             expanded: $shadersExpanded) {
                        model.selection = []
                        model.selectedScript = nil
                    }
                    .padding(.top, 4)

                    if shadersExpanded {
                        ForEach(filteredShaders(.surface)) { shader in
                            shaderRow(shader)
                        }
                        if filteredShaders(.surface).isEmpty {
                            emptyNote(model.shaders(kind: .surface).isEmpty
                                      ? "No shaders yet" : "No matches")
                        }
                    }

                    lightingRow

                    starterPlayerGroup
                    starterPackGroup
                    starterGuiGroup
                    soundServiceGroup
                    assetsGroup

                    animationsGroup

                    // The sheet of glass in front of the camera gets its own category:
                    // it belongs to the view, not to anything in the Workspace.
                    groupRow(title: "Screen",
                             icon: "camera.filters",
                             tint: Color(red: 0.80, green: 0.66, blue: 0.95),
                             count: model.shaders(kind: .screen).count,
                             expanded: $screenExpanded) {
                        model.selection = []
                        model.selectedScript = nil
                    }
                    .padding(.top, 4)

                    if screenExpanded {
                        ForEach(filteredShaders(.screen)) { shader in
                            shaderRow(shader)
                        }
                        if filteredShaders(.screen).isEmpty {
                            emptyNote(model.shaders(kind: .screen).isEmpty
                                      ? "No screen effects yet" : "No matches")
                        }
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
            }
        }
        .background(Theme.panel)
        .onAppear {
            reveal(model.selectedDataObject)
            reveal(node: model.selectedEmitter?.part)
        }
        .onChange(of: model.selectedDataObject) { id in reveal(id) }
        .onChange(of: model.selectedLight) { id in reveal(node: id.flatMap(model.lightParent)) }
        .onChange(of: model.selectedEmitter) { ref in reveal(node: ref?.part) }
        .onChange(of: model.selectedConstraint) { id in
            // A joint, Beam or Trail: the part (or Model) it's under.
            reveal(node: id.flatMap(model.constraint(id:))?.parentID)
        }
    }

    /// Opens a part or Model (an emitter's, a joint's), and what that's inside.
    private func reveal(node start: UUID?) {
        var node = start
        for _ in 0..<64 {
            guard let id = node else { break }
            expandedParts.insert(id)
            node = model.parentID(of: id)
        }
    }

    /// Opens the Models and parts a data object (a Humanoid in a Rig) is inside, so its
    /// row shows when it's picked.
    private func reveal(_ id: UUID?) {
        // Up through any Folders of data to the part or Model it's in, then up the tree.
        var parent = id.flatMap { model.dataObject(id: $0)?.parent }
        for _ in 0..<64 {
            guard case .node(let node) = parent else { return }
            guard let object = model.dataObject(id: node) else { break }
            parent = object.parent
        }
        guard case .node(var node) = parent, model.part(id: node) != nil || model.group(id: node) != nil else { return }
        for _ in 0..<64 {
            expandedParts.insert(node)
            guard let up = model.parentID(of: node) else { break }
            node = up
        }
        workspaceExpanded = true
    }

    // MARK: - Rows

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.text)
            if !filter.isEmpty {
                Button { filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.panelAlt)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textDim)
            .padding(.leading, 30)
            .padding(.vertical, 6)
    }

    private func groupRow(title: String, icon: String, tint: Color, count: Int,
                          expanded: Binding<Bool>, selected: Bool = false,
                          onTap: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Button { expanded.wrappedValue.toggle() } label: {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(tint)
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            Spacer()
            Text("\(count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private func partRow(_ part: Part, depth: Int = 0) -> some View {
        let selected = model.selection.contains(part.id)
        let attached = model.scripts(parentID: part.id)
        return HStack(spacing: 6) {
            if !hasChildren(part.id) {
                Spacer().frame(width: 12)
            } else {
                Button {
                    if expandedParts.contains(part.id) {
                        expandedParts.remove(part.id)
                    } else {
                        expandedParts.insert(part.id)
                    }
                } label: {
                    Image(systemName: expandedParts.contains(part.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textDim)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            }

            Image(systemName: part.negative ? "minus.square.fill" : part.solid != nil ? "square.stack.3d.up.fill" : part.mesh != nil ? "cube.transparent" : part.shape.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(Color(vec: part.color))
                .frame(width: 14)

            if renamingID == part.id {
                TextField("", text: $renameText, onCommit: { commitPartRename(part.id) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
            } else {
                Text(part.name)
                    .font(.system(size: 12))
                    .foregroundStyle(part.locked ? Theme.textDim : Theme.text)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !attached.isEmpty {
                Image(systemName: "curlybraces")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.textDim)
            }
            if part.locked {
                Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(Theme.textDim)
            }
            if !part.visible {
                Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(Theme.textDim)
            }
            if let light = part.lights.first(where: { $0.enabled }) {
                Image(systemName: "lightbulb.fill").font(.system(size: 9))
                    .foregroundStyle(Color(vec: light.color))
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(selected ? Theme.accent.opacity(0.8) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedScript = nil
            model.selectedShader = nil
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) || flags.contains(.command) {
                if selected { model.selection.remove(part.id) } else { model.selection.insert(part.id) }
            } else {
                model.selection = [part.id]
            }
        }
        .draggable(part.id.uuidString)
        .dropDestination(for: String.self) { items, _ in drop(items, onto: part.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.selection = [part.id]
            controller.focusSelection()
        })
        .contextMenu {
            Button("Rename") {
                renameText = part.name
                renamingID = part.id
            }
            Button("Focus") {
                model.selection = [part.id]
                controller.focusSelection()
            }
            Button("Duplicate") {
                model.selection = [part.id]
                model.duplicateSelected()
            }
            if model.selection.contains(part.id) {
                Button("Group Selection") { model.groupSelection(kind: .model) }
                if model.selection.count >= 2 {
                    Button("Weld Selection") { model.weldSelection() }
                }
            }
            if part.parentID != nil {
                Button("Move to Workspace") { model.move(part.id, to: nil) }
            } else {
                Button("Move to ReplicatedStorage") { model.moveToStorage([part.id], .replicatedStorage) }
                Button("Move to ServerStorage") { model.moveToStorage([part.id], .serverStorage) }
            }
            Divider()
            Button("Add Script") {
                expandedParts.insert(part.id)
                session.openScript(model.addScript(parentID: part.id))
            }
            Button("Add Sound") {
                expandedParts.insert(part.id)
                model.addSound(in: part.id)
            }
            Button("Add Trail") {
                expandedParts.insert(part.id)
                model.addTrail(to: part.id)
            }
            Button("Add VectorForce") {
                expandedParts.insert(part.id)
                model.addVectorForce(to: part.id)
            }
            Menu("Add Light") {
                ForEach(PointLight.Kind.allCases) { kind in
                    Button(kind.rawValue) { expandedParts.insert(part.id); model.addLight(kind, to: part.id) }
                }
            }
            Button("Add SurfaceGui") { expandedParts.insert(part.id); model.addSurfaceGui(to: part.id) }
            Menu("Add ParticleEmitter") {
                ForEach(ParticleEmitter.Preset.allCases) { preset in
                    Button(preset.rawValue) {
                        expandedParts.insert(part.id)
                        model.addEmitter(preset, to: part.id)
                    }
                }
            }
            Button("Add Wren Script") {
                expandedParts.insert(part.id)
                session.openScript(model.addScript(parentID: part.id, language: .wren))
            }
            Button("Add ModuleScript") {
                expandedParts.insert(part.id)
                session.openScript(model.addModuleScript(parentID: part.id, host: .scene))
            }
            if !model.shaders.isEmpty {
                Menu("Shader") {
                    Button("None") { model.assignShader(nil, to: [part.id]) }
                    Divider()
                    ForEach(model.shaders) { shader in
                        Button(shader.name) { model.assignShader(shader.id, to: [part.id]) }
                    }
                }
            }
            Divider()
            Button(part.locked ? "Unlock" : "Lock") {
                model.commit("Toggled lock") { model.update(id: part.id) { $0.locked.toggle() } }
            }
            Button(part.visible ? "Hide" : "Show") {
                model.commit("Toggled visibility") { model.update(id: part.id) { $0.visible.toggle() } }
            }
            Divider()
            Button("Delete", role: .destructive) {
                model.selection = [part.id]
                model.deleteSelected()
            }
        }
    }

    private func scriptRow(_ script: ScriptObject, indent: CGFloat) -> some View {
        let selected = model.selectedScript == script.id
        return HStack(spacing: 6) {
            Image(systemName: script.isModule ? "doc.text.fill" : script.enabled ? "doc.plaintext.fill" : "doc.plaintext")
                .font(.system(size: 10))
                .foregroundStyle(script.isModule ? StorageGroup.moduleTint
                                 : script.enabled ? Color(red: 0.62, green: 0.78, blue: 0.45) : Theme.textDim)
                .frame(width: 14)

            if renamingID == script.id {
                TextField("", text: $renameText, onCommit: { commitScriptRename(script.id) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
            } else {
                Text(script.name)
                    .font(.system(size: 12))
                    .foregroundStyle(script.enabled ? Theme.text : Theme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(script.isModule ? "module" : script.language.badge)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(script.isModule ? StorageGroup.moduleTint
                                 : script.language == .luau ? Color(red: 0.45, green: 0.62, blue: 0.95) : Theme.textDim)
            if !script.enabled {
                Text("off")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, indent)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(selected ? Theme.accent.opacity(0.8) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        // A click selects; a double-click opens the script in a tab, as in Roblox Studio.
        .onTapGesture {
            model.selection = []
            model.selectedShader = nil
            model.selectedScript = script.id
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { session.openScript(script.id) })
        .help("Double-click to open")
        .contextMenu {
            Button("Open") {
                model.selectedScript = script.id
                session.openScript(script.id)
            }
            Button("Rename") {
                renameText = script.name
                renamingID = script.id
            }
            Button(script.enabled ? "Disable" : "Enable") {
                model.commit(script.enabled ? "Disabled script" : "Enabled script") {
                    model.updateScript(id: script.id) { $0.enabled.toggle() }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteScript(id: script.id) }
        }
    }

    private func shaderRow(_ shader: ShaderObject) -> some View {
        let selected = model.selectedShader == shader.id
        let status = session.shaderStatus.status(for: shader.id)
        let users = model.parts.filter { $0.shaderID == shader.id }.count
        let isScreen = shader.kind == .screen
        let isActiveScreen = isScreen && model.screenShaderIDs.contains(shader.id)
        return HStack(spacing: 6) {
            if isScreen {
                // A check box: effects that are on run one after another, top to bottom.
                Button {
                    model.toggleScreenShader(shader.id)
                } label: {
                    Image(systemName: isActiveScreen ? "checkmark.square.fill" : "square")
                        .font(.system(size: 10))
                        .foregroundStyle(isActiveScreen ? Theme.accent : Theme.textDim)
                }
                .buttonStyle(.plain)
                .frame(width: 14)
            } else {
                Image(systemName: shader.enabled ? "paintbrush.pointed.fill" : "paintbrush.pointed")
                    .font(.system(size: 10))
                    .foregroundStyle(shader.enabled ? shaderTint : Theme.textDim)
                    .frame(width: 14)
            }

            if renamingID == shader.id {
                TextField("", text: $renameText, onCommit: { commitShaderRename(shader.id) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
            } else {
                Text(shader.name)
                    .font(.system(size: 12))
                    .foregroundStyle(shader.enabled ? Theme.text : Theme.textDim)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if status.isFailed {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.42))
            } else if status == .compiling {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textDim)
            } else if isActiveScreen {
                Text("on")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            } else if !isScreen, users > 0 {
                Text("\(users)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 20)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(selected ? Theme.accent.opacity(0.8) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = []
            model.selectedScript = nil
            model.selectedShader = shader.id
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { session.openShader(shader.id) })
        .help("Double-click to open")
        .contextMenu {
            Button("Open") {
                model.selectedShader = shader.id
                session.openShader(shader.id)
            }
            Button("Rename") {
                renameText = shader.name
                renamingID = shader.id
            }
            if isScreen {
                Button(isActiveScreen ? "Switch Off" : "Switch On") {
                    model.toggleScreenShader(shader.id)
                }
                Button("Move Up (runs earlier)") { model.moveShader(shader.id, by: -1) }
                Button("Move Down (runs later)") { model.moveShader(shader.id, by: 1) }
            } else if !model.selection.isEmpty {
                Button("Apply to Selection") {
                    model.assignShader(shader.id, to: model.selection)
                }
            }
            Button(shader.enabled ? "Disable" : "Enable") {
                model.commit(shader.enabled ? "Disabled shader" : "Enabled shader") {
                    model.updateShader(id: shader.id) { $0.enabled.toggle() }
                }
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteShader(id: shader.id) }
        }
    }

    // MARK: - Lighting

    /// Lighting, and its Sky, Atmosphere and Clouds under it (picking one shows Lighting).
    private var lightingRow: some View {
        VStack(alignment: .leading, spacing: 1) {
            lightingHeader
            let lighting = model.lighting
            ForEach([("Sky", "moon.stars", lighting.skyObject != nil), ("Atmosphere", "aqi.medium", lighting.atmosphere != nil),
                     ("Clouds", "cloud", lighting.clouds != nil)].filter(\.2), id: \.0) { name, icon, _ in
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Color(red: 0.6, green: 0.78, blue: 0.98))
                        .frame(width: 14)
                    Text(name).font(.system(size: 12)).foregroundStyle(Theme.text)
                    Spacer()
                }
                .padding(.vertical, 3)
                .padding(.leading, 28)
                .contentShape(Rectangle())
                .onTapGesture { model.selectLighting() }
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        model.commit("Removed \(name)") {
                            switch name {
                            case "Sky": model.lighting.skyObject = nil
                            case "Atmosphere": model.lighting.atmosphere = nil
                            default: model.lighting.clouds = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private var lightingHeader: some View {
        let selected = model.lightingSelected
        let lighting = model.lighting
        return HStack(spacing: 5) {
            Spacer().frame(width: 12)
            Image(systemName: lighting.sunDirection.y > 0 ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.98, green: 0.82, blue: 0.35))
            Text("Lighting").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
            Spacer()
            Text(lighting.technology == .rayTraced ? "RT" : lighting.timeOfDay.prefix(5).description)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(lighting.technology == .rayTraced ? Theme.accent : Theme.textDim)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { model.selectLighting() }
        .contextMenu {
            ForEach(LightingTechnology.allCases) { technology in
                Button("Use \(technology.displayName)") {
                    model.commit("Lighting: \(technology.displayName)") { model.lighting.technology = technology }
                }
            }
            Divider()
            if lighting.skyObject == nil { Button("Add Sky") { model.commit("Added Sky") { model.lighting.skyObject = SkySettings() } } }
            if lighting.atmosphere == nil {
                Button("Add Atmosphere") { model.commit("Added Atmosphere") { model.lighting.atmosphere = AtmosphereSettings() } }
            }
            if lighting.clouds == nil { Button("Add Clouds") { model.commit("Added Clouds") { model.lighting.clouds = CloudSettings() } } }
        }
        .help("The sun, sky, shadows and fog — and whether they are ray traced")
    }

    // MARK: - Animations

    private var animationTint: Color { Color(red: 0.95, green: 0.62, blue: 0.45) }

    @ViewBuilder private var animationsGroup: some View {
        groupRow(title: "Animations",
                 icon: "figure.walk",
                 tint: animationTint,
                 count: model.animations.count,
                 expanded: $animationsExpanded) {
            session.showDock(.animation)
        }
        .padding(.top, 4)
        .contextMenu {
            Button("New Animation") {
                model.addAnimation()
                session.showDock(.animation)
            }
            Button("Example: Wave") {
                model.addAnimation(.waveExample())
                session.showDock(.animation)
            }
        }

        if animationsExpanded {
            let shown = model.animations.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            ForEach(shown) { animation in
                animationRow(animation)
            }
            if shown.isEmpty {
                emptyNote(model.animations.isEmpty ? "No animations yet" : "No matches")
            }
        }
    }

    private func animationRow(_ animation: AnimationObject) -> some View {
        let selected = model.selectedAnimation == animation.id
        return HStack(spacing: 6) {
            Image(systemName: animation.looped ? "repeat" : "figure.walk")
                .font(.system(size: 10))
                .foregroundStyle(animationTint)
                .frame(width: 14)
            if renamingID == animation.id {
                TextField("", text: $renameText, onCommit: { commitAnimationRename(animation.id) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
            } else {
                Text(animation.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(String(format: "%.1fs", animation.length))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 20)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(selected ? Theme.accent.opacity(0.8) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedAnimation = animation.id
            session.showDock(.animation)
        }
        .contextMenu {
            Button("Edit") {
                model.selectedAnimation = animation.id
                session.showDock(.animation)
            }
            Button("Rename") {
                renameText = animation.name
                renamingID = animation.id
            }
            Button("Duplicate") {
                model.addAnimation(animation)
                session.showDock(.animation)
            }
            Divider()
            Button("Delete", role: .destructive) { model.deleteAnimation(id: animation.id) }
        }
        .help("Play it from a script: humanoid:LoadAnimation(Animations[\"\(animation.name)\"]):Play()")
    }

    private func commitAnimationRename(_ id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !model.animations.contains(where: { $0.name == trimmed && $0.id != id }) {
            model.editAnimation(id, "Renamed animation") { $0.name = trimmed }
        }
        renamingID = nil
    }

    // MARK: - Assets and Sounds

    /// Pictures and sounds, from a file picker.
    private func importAssets() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = SceneAsset.imageExtensions.union(SceneAsset.soundExtensions)
            .union(SceneAsset.meshExtensions).sorted().compactMap { UTType(filenameExtension: $0) }
        panel.message = "Pictures (PNG, JPEG…), sounds (WAV, MP3, M4A…) and 3D models (OBJ, STL, PLY, USDZ) — kept inside the scene when it's saved"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Brings files in, saying in the status bar what couldn't be.
    private func importFiles(_ urls: [URL]) {
        assetsExpanded = true
        for url in urls {
            do { try model.importAsset(from: url) } catch {
                model.statusText = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder private var assetsGroup: some View {
        groupRow(title: "Assets",
                 icon: "photo.on.rectangle",
                 tint: Color(red: 0.85, green: 0.7, blue: 0.95),
                 count: model.assets.count,
                 expanded: $assetsExpanded) {
            model.selectedAsset = nil
        }
        .padding(.top, 4)
        .contextMenu { Button("Import Picture, Sound or 3D Model…") { importAssets() } }
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return true
        }
        if assetsExpanded {
            ForEach(model.assets) { asset in assetRow(asset) }
            if model.assets.isEmpty {
                emptyNote("Drop pictures and sounds here")
            }
        }
    }

    private func assetRow(_ asset: SceneAsset) -> some View {
        let selected = model.selectedAsset == asset.id
        return HStack(spacing: 6) {
            Image(systemName: asset.kind == .image ? "photo" : asset.kind == .mesh ? "cube.transparent" : "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.85, green: 0.7, blue: 0.95))
                .frame(width: 14)
            if renamingID == asset.id {
                TextField("", text: $renameText, onCommit: {
                    model.renameAsset(asset.id, to: renameText)
                    renamingID = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            } else {
                Text(asset.name).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(max(asset.data.count / 1024, 1)) KB")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 20)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = []
            model.selectedGui = nil
            model.selectedSound = nil
            model.selectedAsset = asset.id
        }
        .contextMenu {
            if asset.kind == .mesh {
                Button("Insert MeshPart") { session.viewport.insertMeshPart(asset.id) }
                    .disabled(session.isPlaying)
                Divider()
            }
            Button("Copy Reference") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(asset.reference, forType: .string)
            }
            Button("Rename") {
                renameText = asset.name
                renamingID = asset.id
            }
            Button("Delete", role: .destructive) { model.deleteAsset(asset.id) }
        }
    }

    /// SoundService: the Sounds heard everywhere, not from a part.
    @ViewBuilder private var soundServiceGroup: some View {
        groupRow(title: "SoundService",
                 icon: "speaker.wave.2",
                 tint: Color(red: 0.6, green: 0.85, blue: 0.75),
                 count: model.sounds(in: nil).count,
                 expanded: $soundServiceExpanded) {
            model.selectedSound = nil
        }
        .padding(.top, 4)
        .contextMenu { Button("New Sound") { model.addSound(in: nil) } }
        if soundServiceExpanded {
            ForEach(model.sounds(in: nil)) { sound in soundRow(sound, depth: 0) }
            if model.sounds(in: nil).isEmpty {
                emptyNote("Right-click: New Sound")
            }
        }
    }

    func soundRow(_ sound: SceneSound, depth: Int) -> some View {
        fixtureRow(id: sound.id, depth: depth, name: sound.name, icon: "speaker.wave.2.fill",
                   tint: Color(red: 0.6, green: 0.85, blue: 0.75),
                   selected: model.selectedSound == sound.id && model.selection.isEmpty,
                   detail: sound.playing ? "plays" : "") {
            model.selection = []
            model.selectedGui = nil
            model.selectedAsset = nil
            model.selectedConstraint = nil
            model.selectedAttachment = nil
            model.selectedSound = sound.id
        } delete: {
            model.deleteSound(sound.id)
        }
    }

    // MARK: - StarterGui

    /// StarterGui's objects, as far down as they are expanded.
    private var guiRows: [(object: StarterGuiObject, depth: Int)] {
        var rows: [(StarterGuiObject, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for object in model.guiChildren(of: parent) where object.worldParent == nil {
                rows.append((object, depth))
                if expandedParts.contains(object.id) { walk(object.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return rows
    }

    /// StarterGui: GUIs made here, which every player gets a copy of when they join.
    @ViewBuilder private var starterGuiGroup: some View {
        groupRow(title: "StarterGui",
                 icon: "rectangle.on.rectangle",
                 tint: Color(red: 0.55, green: 0.8, blue: 0.95),
                 count: model.guiChildren(of: nil).filter { $0.worldParent == nil }.count,
                 expanded: $starterGuiExpanded) {
            model.selectedGui = nil
        }
        .padding(.top, 4)
        .contextMenu {
            Button("New ScreenGui") { model.addGuiObject(.screenGui, in: nil) }
            Button("Insert Default HUD") {
                starterGuiExpanded = true
                model.addDefaultHud()
            }
            .help("The health bar, controls, numbers, crosshair and script output a new scene starts with, and F to fly, R to respawn")
        }

        if starterGuiExpanded {
            ForEach(guiRows, id: \.object.id) { row in
                guiRow(row.object, depth: row.depth)
                if expandedParts.contains(row.object.id) {
                    viewportChildRows(row.object, depth: row.depth)
                    ForEach(model.guiScripts(in: row.object.id)) { script in
                        scriptRow(script, indent: 40 + CGFloat(row.depth + 1) * 14)
                    }
                }
            }
            if model.starterGui.isEmpty {
                emptyNote("Right-click: New ScreenGui")
            }
        }
    }

    @ViewBuilder private func viewportChildRows(_ object: StarterGuiObject, depth: Int) -> some View {
        if let content = object.viewportContent {
            ForEach(content.parts) { part in
                fixtureRow(id: part.id, depth: depth + 1, name: part.name, icon: part.shape.symbolName,
                           tint: Theme.accent, selected: model.selectedGui == object.id && model.selectedViewportMember == part.id, detail: "preview") {
                    model.selectedGui = object.id; model.selectedViewportMember = part.id
                } delete: { model.editViewport(object.id, label: "Deleted preview part") { $0.parts.removeAll { $0.id == part.id } } }
            }
            ForEach(content.cameras) { camera in
                fixtureRow(id: camera.id, depth: depth + 1, name: camera.name, icon: "camera", tint: Theme.accent,
                           selected: model.selectedGui == object.id && model.selectedViewportMember == camera.id, detail: "preview") {
                    model.selectedGui = object.id; model.selectedViewportMember = camera.id
                } delete: { model.editViewport(object.id, label: "Deleted preview camera") { $0.cameras.removeAll { $0.id == camera.id }; if $0.currentCamera == camera.id { $0.currentCamera = nil } } }
            }
        }
    }

    private func guiRow(_ object: StarterGuiObject, depth: Int) -> some View {
        let selected = model.selectedGui == object.id && model.selection.isEmpty
        let hasInside = !model.guiChildren(of: object.id).isEmpty || !model.guiScripts(in: object.id).isEmpty
            || object.viewportContent?.parts.isEmpty == false || object.viewportContent?.cameras.isEmpty == false
        return HStack(spacing: 6) {
            Button { toggleExpanded(object.id) } label: {
                Image(systemName: expandedParts.contains(object.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .opacity(hasInside ? 1 : 0.25)
            Image(systemName: object.kind.symbolName)
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.55, green: 0.8, blue: 0.95))
                .frame(width: 14)
            if renamingID == object.id {
                TextField("", text: $renameText, onCommit: {
                    model.renameGuiObject(object.id, to: renameText)
                    renamingID = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
            } else {
                Text(object.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(object.kind.rawValue)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 20 + CGFloat(depth) * 14)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = []
            model.selectedScript = nil
            model.selectedShader = nil
            model.selectedGui = object.id
        }
        .contextMenu {
            Menu("Insert") {
                ForEach(GuiObject.Kind.insertableObjects, id: \.self) { kind in
                    Button(kind.rawValue) {
                        expandedParts.insert(object.id)
                        model.addGuiObject(kind, in: object.id)
                    }
                }
                Divider()
                ForEach(GuiObject.Kind.insertableModifiers, id: \.self) { kind in
                    Button(kind.rawValue) {
                        expandedParts.insert(object.id)
                        model.addGuiObject(kind, in: object.id)
                    }
                    .disabled(kind.needsGuiObject && object.kind.isLayer)
                }
            }
            Button("Duplicate") { model.duplicateGui(object.id) }
            Button("Add LocalScript") {
                expandedParts.insert(object.id)
                session.openScript(model.addScript(parentID: object.id, host: .starterGui))
            }
            Divider()
            Button("Rename") {
                renameText = object.name
                renamingID = object.id
            }
            Button("Delete", role: .destructive) { model.deleteGuiObject(object.id) }
        }
    }

    // MARK: - StarterPack

    /// StarterPack: tools every player is given a copy of when their character spawns.
    @ViewBuilder private var starterPackGroup: some View {
        groupRow(title: "StarterPack",
                 icon: "backpack.fill",
                 tint: Color(red: 0.8, green: 0.8, blue: 0.85),
                 count: model.starterPackTools.count,
                 expanded: $starterPackExpanded) {
            model.selection = []
        }
        .padding(.top, 4)

        if starterPackExpanded {
            ForEach(starterPackRows, id: \.self) { row in
                switch row {
                case .node(.part(let id), let depth):
                    if let part = model.part(id: id) { partRow(part, depth: depth + 1) }
                case .node(.group(let id), let depth):
                    if let group = model.group(id: id) { treeGroupRow(group, depth: depth + 1) }
                case .script(let id, let depth):
                    if let script = model.script(id: id) { scriptRow(script, indent: 40 + CGFloat(depth) * 14) }
                case .sound(let id, let depth):
                    if let sound = model.sound(id: id) { soundRow(sound, depth: depth + 1) }
                case .gui(let id, let depth):
                    if let object = model.guiObject(id: id) {
                        guiRow(object, depth: depth + 1)
                        if expandedParts.contains(id) { viewportChildRows(object, depth: depth + 1) }
                    }
                case .attachment, .constraint, .data, .emitter, .light:
                    EmptyView()
                }
            }
            if model.starterPackTools.isEmpty {
                emptyNote("Right-click a Tool: Move to StarterPack")
            }
        }
    }

    // MARK: - StarterPlayer

    private var starterTint: Color { Color(red: 0.95, green: 0.72, blue: 0.38) }

    /// StarterPlayer: the character template, plus the scripts that run for the
    /// player and for each character — the built-in ones listed until replaced.
    @ViewBuilder private var starterPlayerGroup: some View {
        groupRow(title: "StarterPlayer",
                 icon: "figure.stand",
                 tint: starterTint,
                 count: model.scripts(host: .starterPlayer).count + model.scripts(host: .starterCharacter).count,
                 expanded: $starterExpanded,
                 selected: model.starterPlayerSelected) {
            model.selectStarterPlayer()
        }
        .padding(.top, 4)

        if starterExpanded {
            starterFolder(.starterPlayer, expanded: $playerScriptsExpanded)
            starterFolder(.starterCharacter, expanded: $characterScriptsExpanded)
        }
    }

    @ViewBuilder
    private func starterFolder(_ host: ScriptHost, expanded: Binding<Bool>) -> some View {
        let own = model.scripts(host: host)
        let defaults = model.defaultScripts(host: host)
        HStack(spacing: 5) {
            Button { expanded.wrappedValue.toggle() } label: {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(starterTint.opacity(0.8))
            Text(host.displayName).font(.system(size: 12)).foregroundStyle(Theme.text)
            Spacer()
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 12)
        .contentShape(Rectangle())
        .contextMenu {
            Button("New Script") {
                expanded.wrappedValue = true
                session.openScript(model.addScript(host: host))
            }
        }

        if expanded.wrappedValue {
            ForEach(defaults) { core in
                coreScriptRow(core)
            }
            ForEach(own.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }) { script in
                scriptRow(script, indent: 38)
            }
            if own.isEmpty && defaults.isEmpty {
                emptyNote("Empty")
            }
        }
    }

    private func coreScriptRow(_ script: ScriptObject) -> some View {
        let selected = model.selectedCoreScript == script.name
        return HStack(spacing: 6) {
            Image(systemName: "lock.doc")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
                .frame(width: 14)
            Text(script.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("default")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 38)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectCoreScript(named: script.name)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { session.openCoreScript(named: script.name) })
        .contextMenu {
            Button("View") {
                model.selectCoreScript(named: script.name)
                session.openCoreScript(named: script.name)
            }
            Button("Edit a Copy") {
                if let copy = model.copyCoreScript(named: script.name) { session.openScript(copy) }
            }
            Button("Turn Off") {
                // A disabled script of the same name replaces the default with nothing.
                let id = model.copyCoreScript(named: script.name)
                if let id {
                    model.commit("Disabled \(script.name)") { model.updateScript(id: id) { $0.enabled = false } }
                }
            }
        }
        .help("Built in. \"Edit a Copy\" makes an editable \(script.name) that replaces it.")
    }

    // MARK: - Renaming

    private func commitPartRename(_ id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            model.commit("Renamed part") { model.update(id: id) { $0.name = trimmed } }
        }
        renamingID = nil
    }

    private func commitShaderRename(_ id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            model.commit("Renamed shader") { model.updateShader(id: id) { $0.name = trimmed } }
        }
        renamingID = nil
    }

    private func commitScriptRename(_ id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            model.commit("Renamed script") { model.updateScript(id: id) { $0.name = trimmed } }
        }
        renamingID = nil
    }
}

struct PanelHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textDim)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.textDim)
            Spacer()
            trailing
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.ribbon)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)
    }
}

// MARK: - The Workspace tree

/// One line of the Workspace tree.
enum ExplorerTreeRow: Hashable {
    case node(TreeNode, depth: Int)
    case script(UUID, depth: Int)
    case attachment(UUID, depth: Int)
    case constraint(UUID, depth: Int)
    case sound(UUID, depth: Int)
    /// A Humanoid, Value or Folder inside a part or Model.
    case data(UUID, depth: Int)
    /// A ParticleEmitter in a part.
    case emitter(EmitterRef, depth: Int)
    case light(UUID, depth: Int)
    case gui(UUID, depth: Int)
}

extension ExplorerView {

    /// The Workspace tree, flattened to the rows that are showing: expanded nodes show
    /// their children and scripts. A filter shows every match, flat.
    var treeRows: [ExplorerTreeRow] {
        if !filter.isEmpty {
            var rows: [ExplorerTreeRow] = []
            for group in model.groups where group.name.localizedCaseInsensitiveContains(filter) {
                rows.append(.node(.group(group.id), depth: 0))
            }
            for part in model.parts where part.name.localizedCaseInsensitiveContains(filter) {
                rows.append(.node(.part(part.id), depth: 0))
            }
            return rows
        }

        return rows(under: nil)
    }

    /// The tree below a node (nil for the Workspace), as far as it is expanded.
    func rows(under root: UUID?) -> [ExplorerTreeRow] {
        var childrenOf: [UUID?: [TreeNode]] = [:]
        // A Tool in StarterPack is listed there, not in the Workspace.
        for group in model.groups where group.parentID != nil || model.isInWorkspace(group) {
            childrenOf[group.parentID, default: []].append(.group(group.id))
        }
        // A part kept in storage is listed there, too.
        for part in model.parts where part.parentID != nil || part.storage == nil {
            childrenOf[part.parentID, default: []].append(.part(part.id))
        }
        var scriptsOf: [UUID: [UUID]] = [:]
        for script in model.scripts where script.host == .scene {
            if let parent = script.parentID { scriptsOf[parent, default: []].append(script.id) }
        }

        var rows: [ExplorerTreeRow] = []
        var visited: Set<UUID> = []
        func guis(_ objects: [StarterGuiObject], depth: Int) {
            for object in objects {
                rows.append(.gui(object.id, depth: depth))
                if expandedParts.contains(object.id) {
                    guis(model.guiChildren(of: object.id), depth: depth + 1)
                    for script in model.guiScripts(in: object.id) { rows.append(.script(script.id, depth: depth + 1)) }
                }
            }
        }
        // Data objects, and what's inside them (a Folder's Values), all showing.
        func data(in parent: DataParent, depth: Int) {
            for object in model.dataObjects(in: parent) where visited.insert(object.id).inserted {
                rows.append(.data(object.id, depth: depth))
                data(in: .node(object.id), depth: depth + 1)
            }
        }
        func walk(_ parent: UUID?, depth: Int) {
            for child in childrenOf[parent] ?? [] where visited.insert(child.id).inserted {
                rows.append(.node(child, depth: depth))
                if expandedParts.contains(child.id) {
                    walk(child.id, depth: depth + 1)
                    for script in scriptsOf[child.id] ?? [] { rows.append(.script(script, depth: depth + 1)) }
                    for attachment in model.attachments(on: child.id) {
                        rows.append(.attachment(attachment.id, depth: depth + 1))
                    }
                    for constraint in model.constraints(under: child.id) {
                        rows.append(.constraint(constraint.id, depth: depth + 1))
                    }
                    for sound in model.sounds(in: child.id) where model.part(id: child.id) != nil {
                        rows.append(.sound(sound.id, depth: depth + 1))
                    }
                    for light in model.part(id: child.id)?.lights ?? [] { rows.append(.light(light.id, depth: depth + 1)) }
                    guis(model.starterGui.filter { $0.worldParent == child.id }, depth: depth + 1)
                    for emitter in model.part(id: child.id)?.emitters ?? [] {
                        rows.append(.emitter(EmitterRef(part: child.id, emitter: emitter.id), depth: depth + 1))
                    }
                    data(in: .node(child.id), depth: depth + 1)
                }
            }
        }
        walk(root, depth: 0)
        return rows
    }

    /// StarterPack's tools, each with what is inside it when expanded.
    var starterPackRows: [ExplorerTreeRow] {
        var rows: [ExplorerTreeRow] = []
        for tool in model.starterPackTools {
            rows.append(.node(.group(tool.id), depth: 0))
            guard expandedParts.contains(tool.id) else { continue }
            rows += self.rows(under: tool.id).map { row in
                switch row {
                case .node(let node, let depth): return .node(node, depth: depth + 1)
                case .script(let id, let depth): return .script(id, depth: depth + 1)
                case .attachment(let id, let depth): return .attachment(id, depth: depth + 1)
                case .sound(let id, let depth): return .sound(id, depth: depth + 1)
                case .constraint(let id, let depth): return .constraint(id, depth: depth + 1)
                case .data(let id, let depth): return .data(id, depth: depth + 1)
                case .emitter(let ref, let depth): return .emitter(ref, depth: depth + 1)
                case .light(let id, let depth): return .light(id, depth: depth + 1)
                case .gui(let id, let depth): return .gui(id, depth: depth + 1)
                }
            }
            for script in model.scripts where script.host == .scene && script.parentID == tool.id {
                rows.append(.script(script.id, depth: 1))
            }
        }
        return rows
    }

    func hasChildren(_ id: UUID) -> Bool {
        model.parts.contains { $0.parentID == id } || model.groups.contains { $0.parentID == id }
            || model.scripts.contains { $0.parentID == id && $0.host == .scene }
            || model.attachments.contains { $0.parentID == id }
            || model.constraints.contains { $0.parentID == id }
            || model.sounds.contains { $0.parentID == id }
            || !model.dataObjects(in: .node(id)).isEmpty
            || model.part(id: id)?.emitters.isEmpty == false
            || model.part(id: id)?.lights.isEmpty == false
            || model.starterGui.contains { $0.worldParent == id }
    }

    /// Adds a Humanoid, Folder or Value inside a Model, and shows it.
    func addData(_ kind: DataClass, to parent: UUID) {
        expandedParts.insert(parent)
        model.addDataObject(kind, in: .node(parent))
    }

    /// An attachment or a joint, under the part it belongs to.
    func fixtureRow(id: UUID, depth: Int, name: String, icon: String, tint: Color, selected: Bool,
                    detail: String, select: @escaping () -> Void, delete: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Spacer().frame(width: 12)
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint)
                .frame(width: 14)
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(detail)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .contextMenu {
            Button("Delete", role: .destructive, action: delete)
        }
    }

    func toggleExpanded(_ id: UUID) {
        if expandedParts.contains(id) { expandedParts.remove(id) } else { expandedParts.insert(id) }
    }

    /// Dropping ids dragged from the Explorer onto a node (or the Workspace) moves them.
    func drop(_ items: [String], onto parent: UUID?) -> Bool {
        var moved = false
        for item in items {
            guard let id = UUID(uuidString: item) else { continue }
            if model.script(id: id) != nil {
                guard let parent else { continue }     // a loose script belongs in Script Service
                model.commit("Moved script") { model.updateScript(id: id) { $0.parentID = parent } }
                moved = true
            } else if model.canReparent(id, to: parent) {
                model.move(id, to: parent)
                moved = true
            }
        }
        if moved, let parent { expandedParts.insert(parent) }
        return moved
    }

    func treeGroupRow(_ group: SceneGroup, depth: Int) -> some View {
        let selected = model.selection.contains(group.id)
        let isModel = group.kind != .folder
        return HStack(spacing: 6) {
            Button { toggleExpanded(group.id) } label: {
                Image(systemName: expandedParts.contains(group.id) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .opacity(hasChildren(group.id) ? 1 : 0.25)

            Image(systemName: group.kind == .tool ? "hammer.fill" : isModel ? "cube.transparent" : "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(group.kind == .tool ? Color(red: 0.8, green: 0.8, blue: 0.85)
                                 : isModel ? Color(red: 0.62, green: 0.72, blue: 0.95)
                                           : Color(red: 0.85, green: 0.72, blue: 0.4))
                .frame(width: 14)

            if renamingID == group.id {
                TextField("", text: $renameText, onCommit: {
                    model.renameNode(group.id, to: renameText)
                    renamingID = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.text)
            } else {
                Text(group.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(model.partIDs(inSubtree: group.id).count)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .background(RoundedRectangle(cornerRadius: 4)
            .fill(selected ? Theme.accent.opacity(0.35) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(selected ? Theme.accent.opacity(0.8) : Color.clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedScript = nil
            model.selectedShader = nil
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) || flags.contains(.command) {
                if selected { model.selection.remove(group.id) } else { model.selection.insert(group.id) }
            } else {
                model.selection = [group.id]
            }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.selection = [group.id]
            if isModel { controller.focusSelection() } else { toggleExpanded(group.id) }
        })
        .draggable(group.id.uuidString)
        .dropDestination(for: String.self) { items, _ in drop(items, onto: group.id) }
        .contextMenu {
            Button("Rename") {
                renameText = group.name
                renamingID = group.id
            }
            if isModel {
                Button("Focus") {
                    model.selection = [group.id]
                    controller.focusSelection()
                }
            }
            Button("Duplicate") {
                model.selection = [group.id]
                model.duplicateSelected()
            }
            Button("Ungroup") { model.ungroup(group.id) }
            if group.kind == .tool {
                if group.tool?.place == .starterPack {
                    Button("Move to Workspace") { model.moveToWorkspace(group.id) }
                } else {
                    Button("Move to StarterPack") {
                        starterPackExpanded = true
                        model.moveToStarterPack(group.id)
                    }
                }
            } else if group.parentID != nil {
                Button("Move to Workspace") { model.move(group.id, to: nil) }
            } else {
                Button("Move to ReplicatedStorage") { model.moveToStorage([group.id], .replicatedStorage) }
                Button("Move to ServerStorage") { model.moveToStorage([group.id], .serverStorage) }
            }
            Divider()
            Button("New Folder Inside") {
                expandedParts.insert(group.id)
                _ = model.makeGroup(kind: .folder, parent: group.id)
            }
            Button("Add Script") {
                expandedParts.insert(group.id)
                session.openScript(model.addScript(parentID: group.id))
            }
            if group.kind == .model {
                Menu("Add Object") {
                    if !model.dataObjects(in: .node(group.id)).contains(where: { $0.className == .humanoid }) {
                        Button("Humanoid") { addData(.humanoid, to: group.id) }
                    }
                    Button("Folder") { addData(.folder, to: group.id) }
                    ForEach(DataClass.allCases.filter(\.isValue)) { kind in
                        Button(kind.rawValue) { addData(kind, to: group.id) }
                    }
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                model.selection = [group.id]
                model.deleteSelected()
            }
        }
    }
}
