import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession

    var body: some View {
        if session.showingHome {
            HomeView(home: session.home)
        } else {
            editor
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            RibbonView(model: model, session: session)

            HSplitView {
                // The world and every open script or shader share the middle, one tab at
                // a time; the console runs along the bottom beneath them. Not a split
                // view: that shares the height out evenly, and the console would take
                // half the window from the start.
                GeometryReader { geometry in
                    let dockHeight = DockResizeHandle.clamp(session.dockHeight, in: geometry.size.height)
                    VStack(spacing: 0) {
                        DocumentTabBar(model: model, session: session)
                        DocumentArea(model: model, session: session)
                            .frame(maxHeight: .infinity)
                        if session.dockVisible {
                            DockResizeHandle(height: $session.dockHeight, available: geometry.size.height)
                            DockView(model: model, session: session, console: session.console)
                                .frame(height: dockHeight)
                        }
                    }
                }
                .frame(minWidth: 420)

                VStack(spacing: 0) {
                    ExplorerView(model: model, session: session)
                        .frame(minHeight: 160)
                    Rectangle().frame(height: 1).foregroundStyle(Theme.stroke)
                    PropertiesView(model: model, session: session)
                        .frame(minHeight: 240)
                }
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 420)
                .disabled(session.isPlaying)
                .opacity(session.isPlaying ? 0.45 : 1)
            }

            StatusBar(model: model)
        }
        .background(Theme.ribbon)
        .preferredColorScheme(.dark)
    }
}

/// The edge between the middle of the window and the console under it: drag it to
/// give either more room.
struct DockResizeHandle: View {
    @Binding var height: CGFloat
    let available: CGFloat
    @State private var start: CGFloat?

    /// The console keeps at least a few lines, and the middle at least its tab strip
    /// and a usable view.
    static func clamp(_ height: CGFloat, in available: CGFloat) -> CGFloat {
        min(max(height, 90), max(90, available - 230))
    }

    var body: some View {
        Rectangle()
            .fill(Theme.stroke)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let from = start ?? Self.clamp(height, in: available)
                    start = from
                    height = Self.clamp(from - drag.translation.height, in: available)
                }
                .onEnded { _ in start = nil })
            .background(Theme.ribbon)
    }
}

/// Hints drawn over the viewport: controls legend and live transform readout.
/// Run mode's badge: the scene is live, and Stop puts it back.
struct RunOverlay: View {
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("RUNNING")
                .font(.system(size: 10, weight: .bold))
                .tracking(1)
                .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 0.45))
            Button(action: onStop) {
                HStack(spacing: 5) {
                    Image(systemName: "stop.fill").font(.system(size: 10))
                    Text("Stop").font(.system(size: 11, weight: .medium))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color(red: 0.78, green: 0.30, blue: 0.28)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

struct ViewportOverlay: View {
    @ObservedObject var model: SceneModel
    /// While the GUI tab edits StarterGui, what to do there instead of the camera keys.
    var guiHint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let kind = model.joinTool {
                toolBanner(kind)
            }

            Group {
                if let guiHint {
                    Text(guiHint)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.text)
                } else {
                    HStack(spacing: 10) {
                        legend("Orbit", "right-drag / drag")
                        legend("Pan", "⇧right-drag")
                        legend("Zoom", "scroll")
                        legend("Fly", "right-drag + WASD")
                        legend("Focus", "F")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.45)))

            if model.selection.count == 1, let part = model.selectedParts.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    readout("pos", part.position)
                    readout("size", part.size)
                    readout("rot", part.rotationDegrees)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.black.opacity(0.45)))
            }
        }
        .padding(12)
        .allowsHitTesting(false)
    }

    /// What the armed weld or joint tool is waiting for.
    private func toolBanner(_ kind: SceneConstraint.Kind) -> some View {
        let held = model.joinPending.flatMap { model.part(id: $0)?.name }
        return HStack(spacing: 7) {
            Image(systemName: kind.symbolName).font(.system(size: 11))
            Text("\(kind.displayName) tool").font(.system(size: 11, weight: .semibold))
            Text(held.map { "\($0) → click the second part" } ?? "click the first part")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
            Text("Esc to stop").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.85)))
    }

    private func legend(_ name: String, _ keys: String) -> some View {
        HStack(spacing: 4) {
            Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.text)
            Text(keys).font(.system(size: 10)).foregroundStyle(Theme.textDim)
        }
    }

    private func readout(_ label: String, _ v: Vec3) -> some View {
        Text(String(format: "%@  %.2f, %.2f, %.2f", label, v.x, v.y, v.z))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(Theme.textDim)
    }
}

/// Which set of ribbon groups is showing. The ribbon grew past what one row can hold,
/// so the groups live on tabs — Roblox Studio does the same.
enum RibbonTab: String, CaseIterable, Identifiable {
    case home, model, gui, physics, script, view

    var id: String { rawValue }
    var title: String { self == .gui ? "GUI" : rawValue.capitalized }
}

struct RibbonView: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession

    private var controller: ViewportController { session.viewport }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Rectangle().frame(height: 1).foregroundStyle(Theme.stroke)
            HStack(alignment: .top, spacing: 14) {
                switch session.ribbonTab {
                case .home: homeGroups
                case .model: modelGroups
                case .gui: GuiRibbonGroups(model: model, session: session, editor: session.guiEditor)
                case .physics: physicsGroups
                case .script: scriptGroups
                case .view: viewGroups
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // One height for every tab, so the viewport never jumps as they change.
            .frame(height: 88, alignment: .topLeading)
        }
        .background(Theme.ribbon)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(RibbonTab.allCases) { tab in
                let selected = session.ribbonTab == tab
                Button { session.ribbonTab = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.text : Theme.textDim)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(selected ? Theme.panelAlt : Color.clear))
                        .overlay(Rectangle().frame(height: 2)
                            .foregroundStyle(selected ? Theme.accent : Color.clear), alignment: .bottom)
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 12)

            // Within reach whichever tab is open.
            quickButton("arrow.uturn.backward", "Undo", enabled: model.canUndo) { model.undo() }
            quickButton("arrow.uturn.forward", "Redo", enabled: model.canRedo) { model.redo() }
            Rectangle().frame(width: 1, height: 18).foregroundStyle(Theme.stroke).padding(.horizontal, 4)
            quickButton(session.isPlaying ? "stop.fill" : "play.fill",
                        session.isPlaying ? "Stop the play test" : "Play test this scene",
                        tint: session.isPlaying ? Color(red: 0.90, green: 0.42, blue: 0.38)
                                                : Color(red: 0.55, green: 0.85, blue: 0.45)) {
                session.togglePlay()
            }
            quickButton("gearshape.2", "Run: the scene's scripts and physics, no player (F8)",
                        enabled: !session.isPlaying) {
                session.startRun()
            }
            quickButton("figure.walk", "Open this scene in the client", enabled: !session.isPlaying) {
                LaunchClient.launch(with: model)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 5)
    }

    // MARK: - Groups, tab by tab

    @ViewBuilder private var homeGroups: some View {
        group("Tools") {
            ForEach(GizmoMode.allCases) { mode in
                RibbonButton(title: mode.displayName,
                             icon: mode.symbolName,
                             active: model.joinTool == nil && model.gizmoMode == mode) {
                    model.selectGizmo(mode)
                }
            }
            RibbonButton(title: "Weld", icon: "link", active: model.joinTool == .weld) {
                toggleTool(.weld)
            }
        }

        divider

        group("Insert") {
            ForEach(PartShape.allCases) { shape in
                RibbonButton(title: shape.displayName, icon: shape.symbolName) {
                    controller.insertPart(shape: shape, atScreenPoint: nil)
                }
            }
            RibbonMeshButton(model: model, session: session)
            RibbonButton(title: "Rig", icon: "figure.stand") { controller.insertRig() }
        }

        divider

        group("Edit") {
            RibbonButton(title: "Duplicate", icon: "plus.square.on.square", enabled: !model.selection.isEmpty) {
                model.duplicateSelected()
            }
            RibbonButton(title: "Delete", icon: "trash", enabled: !model.selection.isEmpty) {
                model.deleteSelected()
            }
            RibbonButton(title: "Group", icon: "cube.transparent", enabled: !model.selection.isEmpty) {
                model.groupSelection(kind: .model)
            }
            RibbonButton(title: "Ungroup", icon: "square.dashed", enabled: canUngroup) { ungroup() }
        }
    }

    @ViewBuilder private var modelGroups: some View {
        group("Arrange") {
            RibbonButton(title: "Model", icon: "cube.transparent", enabled: !model.selection.isEmpty) {
                model.groupSelection(kind: .model)
            }
            RibbonButton(title: "Folder", icon: "folder", enabled: !model.selection.isEmpty) {
                model.groupSelection(kind: .folder)
            }
            RibbonButton(title: "Ungroup", icon: "square.dashed", enabled: canUngroup) { ungroup() }
        }

        divider

        group("Select") {
            RibbonButton(title: "All", icon: "checkmark.square") { model.selectAll() }
            RibbonButton(title: "None", icon: "xmark.square", enabled: !model.selection.isEmpty) {
                model.selection = []
            }
        }

        divider

        group("Snap") {
            VStack(alignment: .leading, spacing: 3) {
                Toggle("Snap", isOn: $model.snapEnabled)
                Toggle("Grid", isOn: $model.showGrid)
                Toggle("Local", isOn: $model.localSpace)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 10))
            .foregroundStyle(Theme.text)

            VStack(alignment: .leading, spacing: 3) {
                snapPicker("Move", value: $model.moveSnap, options: [0.05, 0.25, 0.5, 1, 2, 4])
                snapPicker("Rotate", value: $model.rotateSnap, options: [1, 5, 15, 30, 45, 90])
                snapPicker("Size", value: $model.scaleSnap, options: [0.05, 0.25, 0.5, 1, 2])
            }
        }
    }

    @ViewBuilder private var physicsGroups: some View {
        group("Join tools") {
            ForEach(SceneConstraint.Kind.allCases.filter { !$0.isEffect && $0.joinsTwoParts }) { kind in
                RibbonButton(title: kind.displayName, icon: kind.symbolName,
                             active: model.joinTool == kind) {
                    toggleTool(kind)
                }
            }
        }

        divider

        // Not joints: a Beam is picked like one (click two parts); a Trail goes on a part.
        group("Effects") {
            RibbonButton(title: "Beam", icon: SceneConstraint.Kind.beam.symbolName, active: model.joinTool == .beam) {
                toggleTool(.beam)
            }
            RibbonButton(title: "Trail", icon: SceneConstraint.Kind.trail.symbolName,
                         enabled: model.selectedParts.count == 1) {
                if let part = model.selectedParts.first { model.addTrail(to: part.id) }
            }
        }

        divider

        // A push on the selected part (Align Position and No Collision are join tools).
        group("Forces") {
            RibbonButton(title: "VectorForce", icon: SceneConstraint.Kind.vectorForce.symbolName,
                         enabled: model.selectedParts.count == 1) {
                if let part = model.selectedParts.first { model.addVectorForce(to: part.id) }
            }
        }

        divider

        group("Selection") {
            RibbonButton(title: "Weld All", icon: "square.stack.3d.up", enabled: model.selectedParts.count >= 2) {
                model.weldSelection()
            }
            RibbonButton(title: "Unjoin", icon: "scissors", enabled: !model.selection.isEmpty) {
                model.unjoinSelection()
            }
        }

        divider

        group("How the tools work") {
            VStack(alignment: .leading, spacing: 5) {
                Toggle("Join the whole selection when a tool is picked", isOn: $model.joinSelectionOnPick)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.text)
                Text(toolHint)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var scriptGroups: some View {
        group("Script") {
            RibbonButton(title: "New", icon: "doc.badge.plus", enabled: !session.isPlaying) {
                let parent = model.selection.count == 1 ? model.selection.first : nil
                session.openScript(model.addScript(parentID: parent))
            }
            RibbonButton(title: "Wren", icon: "doc.badge.gearshape", enabled: !session.isPlaying) {
                let parent = model.selection.count == 1 ? model.selection.first : nil
                session.openScript(model.addScript(parentID: parent, language: .wren))
            }
            RibbonButton(title: "Open", icon: "curlybraces",
                         active: isShowing { if case .script = $0 { return true } else { return false } },
                         enabled: !model.scripts.isEmpty) {
                if let id = model.selectedScript ?? model.scripts.first?.id { session.openScript(id) }
            }
        }

        divider

        group("Shader") {
            RibbonButton(title: "Surface", icon: "paintbrush.pointed", enabled: !session.isPlaying) {
                let id = model.addShader(kind: .surface)
                if !model.selection.isEmpty { model.assignShader(id, to: model.selection) }
                session.openShader(id)
            }
            RibbonButton(title: "Effect", icon: "camera.filters", enabled: !session.isPlaying) {
                session.openShader(model.addShader(kind: .screen))
            }
            RibbonButton(title: "Open", icon: "paintpalette",
                         active: isShowing { if case .shader = $0 { return true } else { return false } },
                         enabled: !model.shaders.isEmpty) {
                if let id = model.selectedShader ?? model.shaders.first?.id { session.openShader(id) }
            }
        }

        divider

        group("Animate") {
            RibbonButton(title: "Animate", icon: "figure.walk",
                         active: session.dockVisible && session.dockTab == .animation,
                         enabled: !session.isPlaying) {
                if model.selectedAnimation == nil {
                    model.selectedAnimation = model.animations.first?.id ?? model.addAnimation()
                }
                session.showDock(.animation)
            }
        }

        divider

        group("Output") {
            RibbonButton(title: "Output", icon: "text.alignleft",
                         active: session.dockVisible && session.dockTab == .output) {
                session.showDock(.output)
            }
            RibbonButton(title: "Clear", icon: "clear") { session.console.clear() }
        }
    }

    @ViewBuilder private var viewGroups: some View {
        group("Camera") {
            RibbonButton(title: "World", icon: "globe.americas.fill", active: session.worldInFront) {
                session.showWorld()
            }
            RibbonButton(title: "Focus", icon: "scope") {
                session.showWorld()
                controller.focusSelection()
            }
        }

        divider

        group("Show") {
            RibbonButton(title: "Grid", icon: "grid", active: model.showGrid) { model.showGrid.toggle() }
            RibbonButton(title: "Local", icon: "rotate.3d", active: model.localSpace) { model.localSpace.toggle() }
            RibbonButton(title: "Snap", icon: "ruler", active: model.snapEnabled) { model.snapEnabled.toggle() }
            RibbonButton(title: "Output", icon: "rectangle.bottomthird.inset.filled",
                         active: session.dockVisible) {
                session.dockVisible.toggle()
            }
            RibbonButton(title: "GUI", icon: "rectangle.on.rectangle", active: session.showsGuiPreview) {
                session.showsGuiPreview.toggle()
            }
            .help("Show StarterGui over the world while editing (the HUD among it)")
        }

        divider

        group("Scene") {
            RibbonButton(title: "Lighting", icon: "sun.max", active: model.lightingSelected) {
                model.selectLighting()
            }
            RibbonButton(title: "Player", icon: "person", active: model.starterPlayerSelected) {
                model.selectStarterPlayer()
            }
        }
    }

    // MARK: - Pieces

    /// What the Physics tab says under the toggle: what the armed tool wants next.
    private var toolHint: String {
        guard let kind = model.joinTool else {
            return "Pick a tool, then click the two parts to join. Or select parts first and pick a tool."
        }
        if model.joinPending != nil {
            return "\(kind.displayName) tool: click the second part · Esc to stop."
        }
        return "\(kind.displayName) tool: click the first part · Esc to stop."
    }

    /// Picking the armed tool again puts it away.
    private func toggleTool(_ kind: SceneConstraint.Kind) {
        if model.joinTool == kind {
            model.cancelJoinTool()
        } else {
            model.armJoinTool(kind)
        }
    }

    private var canUngroup: Bool { model.selection.contains { model.group(id: $0) != nil } }

    /// Whether the tab in front is a document of some kind.
    private func isShowing(_ kind: (EditorDocument) -> Bool) -> Bool {
        session.activeDocument.map(kind) ?? false
    }

    private func ungroup() {
        for id in model.selection where model.group(id: id) != nil { model.ungroup(id) }
    }

    private var divider: some View {
        Rectangle().frame(width: 1, height: 44).foregroundStyle(Theme.stroke)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(Theme.textDim.opacity(0.8))
            HStack(alignment: .top, spacing: 5) { content() }
        }
    }

    private func quickButton(_ icon: String, _ help: String, tint: Color = Theme.text,
                             enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .frame(width: 28, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? tint : Theme.textDim.opacity(0.5))
        .disabled(!enabled)
        .help(help)
    }

    private func snapPicker(_ label: String, value: Binding<Float>, options: [Float]) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(Theme.textDim)
                .frame(width: 34, alignment: .leading)
            Picker("", selection: value) {
                ForEach(options, id: \.self) { option in
                    Text(NumericField.format(option)).tag(option)
                }
            }
            .labelsHidden()
            .controlSize(.mini)
            .frame(width: 62)
        }
    }
}

struct RibbonButton: View {
    let title: String
    let icon: String
    var active: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 14))
                Text(title).font(.system(size: 9))
            }
            .frame(width: 54, height: 40)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(active ? Theme.accent.opacity(0.85) : Theme.panelAlt))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Theme.text : Theme.textDim.opacity(0.5))
        .disabled(!enabled)
    }
}

struct StatusBar: View {
    @ObservedObject var model: SceneModel

    var body: some View {
        HStack(spacing: 12) {
            Text(model.statusText)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textDim)
            Spacer()
            Text("\(model.parts.count) parts")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
            Text("\(model.selection.count) selected")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
            if let kind = model.joinTool {
                Text("\(kind.displayName.lowercased()) tool")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.accent)
            }
            Text("\(model.scripts.count) scripts")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
            Text("\(model.shaders.count) shaders")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
            Text(model.snapEnabled ? "snap \(NumericField.format(model.moveSnap))" : "snap off")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.ribbon)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .top)
    }
}
