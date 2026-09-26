import SwiftUI

/// The tab strip across the middle of the window: the world first, then every open
/// script and shader, as in Roblox Studio. The world tab never closes.
struct DocumentTabBar: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession

    var body: some View {
        HStack(spacing: 0) {
            DocumentTab(title: "World", icon: "globe.americas.fill", tint: Theme.accent,
                        active: session.worldInFront, help: "The 3D world") {
                session.showWorld()
            }
            ForEach(session.documents) { document in
                let look = Self.look(of: document, model: model)
                DocumentTab(title: session.title(of: document), icon: look.icon, tint: look.tint,
                            active: session.activeDocument == document,
                            help: look.help,
                            close: { session.close(document) }) {
                    session.open(document)
                }
                .contextMenu {
                    Button("Close Tab") { session.close(document) }
                    Button("Close Other Tabs") { session.closeOtherDocuments(than: document) }
                    Button("Close All Tabs") { session.closeAllDocuments() }
                }
            }
            Spacer(minLength: 0)
            Button { session.toggleSplitView() } label: {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 11))
                    .foregroundStyle(session.splitView ? Theme.accent : Theme.textDim)
                    .frame(width: 26, height: 22)
            }
            .buttonStyle(.plain)
            .help("Split view: the world beside the tab in front (⌘\\)")
            .padding(.trailing, 6)
        }
        .frame(height: 30)
        .background(Theme.ribbon)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)
    }

    static func look(of document: EditorDocument, model: SceneModel) -> (icon: String, tint: Color, help: String) {
        switch document {
        case .script(let id):
            let language = model.script(id: id)?.language ?? .luau
            return ("doc.plaintext.fill", Color(red: 0.62, green: 0.78, blue: 0.45), "\(language.displayName) script")
        case .shader(let id):
            let kind = model.shader(id: id)?.kind ?? .surface
            return (kind.symbolName + ".fill", Color(red: 0.55, green: 0.72, blue: 0.95),
                    kind == .surface ? "Surface shader" : "Screen effect")
        case .coreScript:
            return ("lock.doc.fill", Theme.textDim, "Built-in script, read-only")
        }
    }
}

/// One tab. Tabs share the strip like a browser's: up to a comfortable width each,
/// narrowing — names truncated — as more open.
struct DocumentTab: View {
    let title: String
    let icon: String
    let tint: Color
    let active: Bool
    var help: String = ""
    var close: (() -> Void)? = nil
    let select: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(tint.opacity(active ? 1 : 0.75))
            Text(title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.text : Theme.textDim)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 2)
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(hovering ? Color.white.opacity(0.08) : Color.clear))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
                .opacity(active || hovering ? 1 : 0)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, close == nil ? 12 : 5)
        .frame(minWidth: close == nil ? nil : 72, maxWidth: close == nil ? nil : 180, maxHeight: .infinity)
        .fixedSize(horizontal: close == nil, vertical: false)
        .background(active ? Theme.panel : Color.clear)
        .overlay(Rectangle().frame(height: 2).foregroundStyle(active ? Theme.accent : Color.clear), alignment: .top)
        .overlay(Rectangle().frame(width: 1).foregroundStyle(Theme.stroke), alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The middle of the window: the world, or the document whose tab is in front — or, in
/// split view, both side by side. The viewport never leaves the view tree, nor moves in
/// it — rebuilding it would recompile every Metal pipeline — it is hidden instead, and
/// keeps ticking so a play test runs on and edited shaders still compile.
struct DocumentArea: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession

    var body: some View {
        GeometryReader { geometry in
            let split = session.splitView && session.activeDocument != nil
            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    // Side by side, the viewport takes the keyboard only when clicked.
                    ViewportView(editor: session.viewport, player: session.player, showsWorld: session.showsWorld,
                                 takesKeyboard: !split)
                    if session.showsWorld {
                        if let play = session.player {
                            // The game's own screen and nothing else: what a player sees
                            // is its GUI (the default HUD is StarterGui's PlayerHud).
                            // Stop is Studio's, in the ribbon (⌘P).
                            GuiLayer(store: play.gui)
                        } else {
                            if session.showsGuiPreview {
                                GuiPreviewArea(session: session, model: model, editor: session.guiEditor,
                                               store: session.guiPreview)
                            }
                            ViewportOverlay(model: model, guiHint: session.guiHint)
                            if session.isRunMode { RunOverlay { session.stopPlay() } }
                        }
                    }
                    if !split, let document = session.activeDocument {
                        DocumentView(model: model, session: session, document: document)
                            .id(document.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Theme.panel)
                    }
                }
                .frame(width: split ? geometry.size.width * session.splitFraction : geometry.size.width)
                .clipped()
                if split, let document = session.activeDocument {
                    SplitHandle(fraction: $session.splitFraction, width: geometry.size.width)
                    DocumentView(model: model, session: session, document: document)
                        .id(document.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.panel)
                }
            }
        }
    }
}

/// The line between the world and the tab in split view; dragging it shares the width.
struct SplitHandle: View {
    @Binding var fraction: CGFloat
    let width: CGFloat
    @State private var start: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(width: 1)
            .padding(.horizontal, 2)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let from = start ?? fraction
                    start = from
                    fraction = min(max(from + drag.translation.width / max(width, 1), 0.2), 0.8)
                }
                .onEnded { _ in start = nil })
            .background(Theme.ribbon)
    }
}

/// A document filling the middle of the window.
struct DocumentView: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    let document: EditorDocument

    var body: some View {
        switch document {
        case .script(let id):
            if let script = model.script(id: id) {
                ScriptDocumentView(model: model, session: session, script: script, document: document)
            }
        case .shader(let id):
            if let shader = model.shader(id: id) {
                ShaderDocumentView(model: model, session: session, status: session.shaderStatus,
                                   shader: shader, document: document)
            }
        case .coreScript(let name):
            if let core = CoreScripts.all.first(where: { $0.name == name }) {
                CoreScriptViewer(model: model, session: session, script: core, document: document)
            }
        }
    }
}

/// A script, full size: its header, then the code with line numbers.
struct ScriptDocumentView: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    let script: ScriptObject
    let document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            header(script)
            let language = CodeLanguage(script.language)
            CodeEditor(text: script.source,
                       isEditable: !session.isPlaying,
                       language: language,
                       completions: { [model, id = script.id] text, caret in
                           // Luau sees the scene: what's in each place, and every module's code.
                           language == .luau
                               ? LuauCompletion.items(in: text, caret: caret, scene: model.luauScene(editing: id))
                               : language.completions(in: text, caret: caret)
                       },
                       cache: session.codeViews,
                       cacheKey: document.id,
                       showsLineNumbers: true,
                       focusOnAppear: true,
                       reveal: session.revealRequest(for: document),
                       breakpoints: script.breakpoints,
                       pausedLine: pausedLine,
                       onToggleBreakpoint: script.language == .luau
                           ? { [session, id = script.id] line in session.toggleBreakpoint(script: id, line: line) } : nil,
                       onBreakpointsMoved: { [model, id = script.id] lines in model.setBreakpoints(lines, forScript: id) }
            ) { updated in
                model.setScriptSource(id: script.id, source: updated)
            }
        }
    }

    /// Where the game is stopped in this script: the line of the call the Debugger shows.
    private var pausedLine: Int? {
        guard let frames = session.debugPause?.frames, frames.indices.contains(session.debugFrame),
              frames[session.debugFrame].scriptID == script.id else { return nil }
        return frames[session.debugFrame].line
    }

    private func header(_ script: ScriptObject) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.plaintext.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.62, green: 0.78, blue: 0.45))
            Text(script.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)

            if script.host != .scene {
                Text("in \(script.host.displayName)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            } else if let parentID = script.parentID, let parent = model.part(id: parentID) {
                Text("in \(parent.name)")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            } else {
                Text("standalone")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }

            Spacer()

            if session.isPlaying {
                Text("read-only while playing")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }

            Picker("", selection: Binding(
                get: { script.language },
                set: { newValue in
                    model.commit("Changed script language") {
                        model.updateScript(id: script.id) { $0.language = newValue }
                    }
                })) {
                    ForEach(ScriptLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 96)
                .disabled(session.isPlaying || script.host != .scene)
                .help(script.host == .scene
                      ? "Luau is the primary language. Switching does not translate the code."
                      : "StarterPlayer scripts are Luau: Wren gets player support in a later release.")

            Toggle("Enabled", isOn: Binding(
                get: { script.enabled },
                set: { newValue in
                    model.commit(newValue ? "Enabled script" : "Disabled script") {
                        model.updateScript(id: script.id) { $0.enabled = newValue }
                    }
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
                .foregroundStyle(Theme.text)

            Button {
                session.isPlaying ? session.stopPlay() : session.startPlay()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: session.isPlaying ? "stop.fill" : "play.fill")
                        .font(.system(size: 9))
                    Text(session.isPlaying ? "Stop" : "Run").font(.system(size: 10, weight: .medium))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.panelAlt.opacity(0.5))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)
    }
}

/// A shader, full size: its code with line numbers, its parameters beside it, and how
/// the last compile went underneath.
struct ShaderDocumentView: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    @ObservedObject var status: ShaderStatusStore
    let shader: ShaderObject
    let document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            header(shader)
            HStack(spacing: 0) {
                CodeEditor(text: shader.source,
                           isEditable: !session.isPlaying,
                           language: .metal,
                           completions: { [parameters = shader.parameters.map(\.name), kind = shader.kind] text, caret in
                               MetalCompletion.items(in: text, caret: caret, parameters: parameters, kind: kind)
                           },
                           cache: session.codeViews,
                           cacheKey: document.id,
                           showsLineNumbers: true,
                           focusOnAppear: true,
                           reveal: session.revealRequest(for: document)) { updated in
                    model.setShaderSource(id: shader.id, source: updated)
                }

                Divider().overlay(Theme.stroke)
                sidebar(shader).frame(width: 240)
            }
            diagnostics(shader)
        }
    }

    // MARK: - Header

    private func header(_ shader: ShaderObject) -> some View {
        let state = status.status(for: shader.id)
        let users = model.parts.filter { $0.shaderID == shader.id }.count
        let isActiveScreen = model.screenShaderIDs.contains(shader.id)
        return HStack(spacing: 8) {
            Image(systemName: shader.kind.symbolName + ".fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.55, green: 0.72, blue: 0.95))
            Text(shader.name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)
            if shader.kind == .surface {
                Text(users == 1 ? "on 1 part" : "on \(users) parts")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            } else {
                Text(isActiveScreen ? "in front of the camera" : "switched off")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
            }

            statusBadge(state)

            Spacer()

            Toggle("Enabled", isOn: Binding(
                get: { shader.enabled },
                set: { newValue in
                    model.commit(newValue ? "Enabled shader" : "Disabled shader") {
                        model.updateShader(id: shader.id) { $0.enabled = newValue }
                    }
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
                .foregroundStyle(Theme.text)

            if shader.kind == .screen {
                SmallButton(isActiveScreen ? "Switch off" : "Switch on",
                            icon: isActiveScreen ? "eye.slash" : "eye") {
                    model.toggleScreenShader(shader.id)
                }
            } else if !model.selection.isEmpty {
                SmallButton("Apply to selection", icon: "arrow.down.circle") {
                    model.assignShader(shader.id, to: model.selection)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.panelAlt.opacity(0.5))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)
    }

    private func statusBadge(_ state: ShaderStatus) -> some View {
        let (text, color): (String, Color) = {
            switch state {
            case .idle: return ("not compiled", Theme.textDim)
            case .compiling: return ("compiling…", Theme.textDim)
            case .ready: return ("live", Color(red: 0.55, green: 0.82, blue: 0.50))
            case .failed: return ("error", Color(red: 0.95, green: 0.45, blue: 0.42))
            }
        }()
        return Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(SwiftUI.Capsule().fill(color.opacity(0.15)))
    }

    // MARK: - Sidebar

    private func sidebar(_ shader: ShaderObject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("PARAMETERS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.textDim)

                ForEach(shader.parameters) { parameter in
                    parameterRow(shader, parameter)
                }

                if shader.parameters.count < ShaderObject.maximumParameters {
                    Button {
                        model.commit("Added parameter") {
                            model.updateShader(id: shader.id) { object in
                                object.parameters.append(
                                    ShaderParameter(name: nextParameterName(object), value: 1))
                            }
                        }
                    } label: {
                        Label("Add parameter", systemImage: "plus")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                }

                Divider().overlay(Theme.stroke)

                Text("IN SCOPE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(Theme.textDim)

                ForEach(ShaderSource.inputs(for: shader.kind), id: \.name) { input in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(input.type)  \(input.name)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.text)
                        Text(input.description)
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textDim)
                    }
                }

                Text(shader.kind == .screen
                     ? "Return a float3 colour for this pixel of the screen."
                     : "Return a float3 colour.")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textDim)
                    .padding(.top, 2)
            }
            .padding(10)
        }
        .background(Theme.panel)
    }

    private func parameterRow(_ shader: ShaderObject, _ parameter: ShaderParameter) -> some View {
        let valid = ShaderSource.isValidParameterName(parameter.name)
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                TextField("", text: Binding(
                    get: { parameter.name },
                    set: { newName in
                        model.commit("Renamed parameter") {
                            model.updateShader(id: shader.id) { object in
                                for index in object.parameters.indices
                                where object.parameters[index].id == parameter.id {
                                    object.parameters[index].name = newName
                                }
                            }
                        }
                    }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(valid ? Theme.text : Color(red: 0.95, green: 0.45, blue: 0.42))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.panelAlt))

                Button {
                    model.commit("Removed parameter") {
                        model.updateShader(id: shader.id) { object in
                            object.parameters.removeAll { $0.id == parameter.id }
                        }
                    }
                } label: {
                    Image(systemName: "minus.circle").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
            }

            HStack(spacing: 6) {
                Slider(value: Binding(
                    get: { Double(parameter.value) },
                    set: { newValue in
                        model.beginStroke()
                        model.updateShader(id: shader.id) { object in
                            for index in object.parameters.indices
                            where object.parameters[index].id == parameter.id {
                                object.parameters[index].value = Float(newValue)
                            }
                        }
                    }), in: 0...10) { editing in
                        if !editing { model.endStroke() }
                    }
                    .controlSize(.mini)
                Text(String(format: "%.2f", parameter.value))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.textDim)
                    .frame(width: 32, alignment: .trailing)
            }

            if !valid {
                Text("not a usable name in Metal")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.42))
            }
        }
    }

    private func nextParameterName(_ shader: ShaderObject) -> String {
        let used = Set(shader.parameters.map(\.name))
        var index = 1
        while used.contains("value\(index)") { index += 1 }
        return "value\(index)"
    }

    // MARK: - Diagnostics

    @ViewBuilder
    private func diagnostics(_ shader: ShaderObject) -> some View {
        if case .failed(let problems) = status.status(for: shader.id), !problems.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(problems.prefix(4), id: \.self) { problem in
                    Text(problem)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.42))
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(red: 0.24, green: 0.12, blue: 0.12))
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .top)
        }
    }
}
