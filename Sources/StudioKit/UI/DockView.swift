import SwiftUI

/// The panel along the bottom: the Output console, as in Roblox Studio, and the
/// Animation Editor's timeline when that is open. Scripts and shaders open in tabs
/// above, in place of the world.
struct DockView: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    @ObservedObject var console: ScriptConsole

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Group {
                switch session.dockTab {
                case .output: OutputPanel(model: model, session: session, console: console)
                case .animation: AnimationEditorView(model: model, session: session,
                                                     editor: session.viewport.animationEditor)
                case .debugger: DebuggerPanel(model: model, session: session)
                case .terrain: TerrainEditorView(model: model)
                case .toolbox: ToolboxView(session: session)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.panel)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(DockTab.allCases) { tab in
                DockTabButton(tab: tab,
                              selected: session.dockTab == tab,
                              badge: tab == .output ? console.errorCount : 0) {
                    session.showDock(tab)
                }
            }

            Spacer()

            if session.dockTab == .output {
                Button { console.clear() } label: {
                    Text("Clear").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
            }

            Button { session.dockVisible = false } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textDim)
            .padding(.leading, 6)
            .help("Hide the panel — View ▸ Output brings it back")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.ribbon)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .top)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.stroke), alignment: .bottom)
    }
}

struct DockTabButton: View {
    let tab: DockTab
    let selected: Bool
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.symbolName).font(.system(size: 10))
                Text(tab.title).font(.system(size: 11, weight: .medium))
                if badge > 0 {
                    Text("\(badge)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(SwiftUI.Capsule().fill(Color(red: 0.82, green: 0.32, blue: 0.30)))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.panelAlt : Color.clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Theme.text : Theme.textDim)
    }
}

struct OutputPanel: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    @ObservedObject var console: ScriptConsole

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if console.lines.isEmpty {
                        Text("Press Play to run this scene's scripts. print, warn and errors appear here; click an error to open its script at that line.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textDim)
                            .padding(.vertical, 8)
                    }
                    ForEach(console.lines) { line in
                        row(line).id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .onChange(of: console.lines.count) { _ in
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    /// An error that names a script and a line is a link to it, as in Roblox Studio.
    @ViewBuilder
    private func row(_ line: ScriptConsole.Line) -> some View {
        if line.kind == .error, let target = ConsoleLocation.find(in: line.text).flatMap(document(for:)) {
            Button {
                session.reveal(target.document, line: target.line)
            } label: {
                Text(line.text)
                    .font(.system(size: 11, design: .monospaced))
                    .underline()
                    .foregroundStyle(color(for: line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(session.title(of: target.document)) at line \(target.line)")
        } else {
            Text(line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color(for: line.kind))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The script an error names: one of the scene's, or a built-in one.
    private func document(for location: ConsoleLocation) -> (document: EditorDocument, line: Int)? {
        if let script = model.scripts.first(where: { $0.name == location.scriptName }) {
            return (.script(script.id), location.line)
        }
        if CoreScripts.all.contains(where: { $0.name == location.scriptName }) {
            return (.coreScript(location.scriptName), location.line)
        }
        return nil
    }

    private func color(for kind: ScriptConsole.Kind) -> Color {
        switch kind {
        case .info: return Theme.textDim
        case .output: return Theme.text
        case .warning: return Color(red: 0.96, green: 0.74, blue: 0.36)
        case .error: return Color(red: 0.95, green: 0.45, blue: 0.42)
        }
    }
}
