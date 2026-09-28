import SwiftUI

/// The Debugger tab: while the scripts are stopped at a breakpoint, where (the calls,
/// innermost first — pick one to see its variables and its line) and what each
/// variable holds (tables open to show what's in them), with Continue, Step Over, Step
/// Into, Step Out and Stop; watch expressions, worked out at every stop (the place's);
/// and always, the place's breakpoints, each with how often its line ran, an optional
/// condition, and an optional message that makes it a logpoint. Breakpoints are set by
/// clicking beside a line number.
struct DebuggerPanel: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession
    @State private var newWatch = ""

    var body: some View {
        VStack(spacing: 0) {
            controls
            if let note = session.debugPause?.note {
                Text(note)
                    .foregroundStyle(Self.warning)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 5)
            }
            Divider().overlay(Theme.stroke)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    heading("Call Stack")
                    calls
                    heading("Breakpoints")
                    breakpoints
                }
                .frame(width: 280)
                Divider().overlay(Theme.stroke)
                VStack(alignment: .leading, spacing: 0) {
                    heading("Variables")
                    variables
                }
                .frame(maxWidth: .infinity)
                Divider().overlay(Theme.stroke)
                VStack(alignment: .leading, spacing: 0) {
                    heading("Watch")
                    watchList
                    Divider().overlay(Theme.stroke)
                    TextField("Add a watch, like player.Name", text: $newWatch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .onSubmit {
                            session.addWatch(newWatch)
                            newWatch = ""
                        }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.text)
    }

    private var controls: some View {
        let paused = session.debugPause != nil
        return HStack(spacing: 6) {
            button("Continue", "play.fill", .resume, "Continue (F5)")
            button("Step Over", "arrow.uturn.forward", .stepOver, "Step Over (F10)")
            button("Step Into", "arrow.down.to.line", .stepInto, "Step Into (F11)")
            button("Step Out", "arrow.up.to.line", .stepOut, "Step Out (⇧F11)")
            button("Stop", "stop.fill", .stop, "Stop the game")
            Spacer()
            Text(status)
                .foregroundStyle(paused ? Color(red: 0.98, green: 0.8, blue: 0.35) : Theme.textDim)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .disabled(!paused)
    }

    private var status: String {
        guard let pause = session.debugPause, let top = pause.frames.first else {
            return session.isPlaying ? "Running — the game stops at a breakpoint"
                                     : "Click beside a line number in a Luau script for a breakpoint, then Play"
        }
        return "Stopped at \(top.script):\(top.line)" + (pause.reason == .breakpoint ? " — a breakpoint" : "")
    }

    private func button(_ title: String, _ symbol: String, _ command: ScriptDebugger.Command, _ help: String) -> some View {
        Button { session.debug(command) } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panelAlt))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func heading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private var calls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array((session.debugPause?.frames ?? []).enumerated()), id: \.offset) { index, frame in
                    Button { session.showFrame(index) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: index == 0 ? "arrowtriangle.right.fill" : "circle.fill")
                                .font(.system(size: index == 0 ? 8 : 4))
                                .foregroundStyle(index == 0 ? Color(red: 0.98, green: 0.8, blue: 0.35) : Theme.textDim)
                                .frame(width: 10)
                            Text(frame.function.isEmpty ? "(the script)" : frame.function)
                            Spacer()
                            Text("\(frame.script):\(frame.line)").foregroundStyle(Theme.textDim)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(index == session.debugFrame ? Theme.accent.opacity(0.25) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var breakpoints: some View {
        let all = model.scripts.flatMap { script in script.breakpoints.map { Mark(script: script, line: $0) } }
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if all.isEmpty {
                    Text("None yet").foregroundStyle(Theme.textDim).padding(.horizontal, 10)
                }
                ForEach(all) { mark in
                    let script = mark.script, line = mark.line
                    let condition = script.breakpointConditions[line] ?? ""
                    let log = script.breakpointLogs[line] ?? ""
                    let hits = session.breakpointHits[script.id]?[line] ?? 0
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Circle().fill(!log.isEmpty ? Self.logging : condition.isEmpty ? Color(red: 0.9, green: 0.3, blue: 0.3)
                                                                                         : Self.conditional)
                                .frame(width: 7, height: 7)
                            Button { session.openScript(script.id, line: line) } label: {
                                Text("\(script.name):\(line)")
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            if hits > 0 {
                                Text(hits == 1 ? "1 hit" : "\(hits) hits")
                                    .foregroundStyle(Theme.textDim)
                                    .help("How many times this line ran in the last play")
                            }
                            Button { session.toggleBreakpoint(script: script.id, line: line) } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textDim)
                            .help("Remove this breakpoint")
                        }
                        SettingField(text: condition, placeholder: "Condition — stops always when empty",
                                     help: "Stop here only when this Luau expression is true — say, health < 20",
                                     color: Self.conditional) {
                            session.setBreakpointCondition(script: script.id, line: line, $0)
                        }
                        .padding(.leading, 13)
                        SettingField(text: log, placeholder: "Log message — prints and goes on",
                                     help: "Print this instead of stopping, written as print's arguments — say, \"health\", health",
                                     color: Self.logging) {
                            session.setBreakpointLog(script: script.id, line: line, $0)
                        }
                        .padding(.leading, 13)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: 170)
    }

    static let warning = Color(red: 0.98, green: 0.62, blue: 0.3)
    static let conditional = Color(red: 0.92, green: 0.52, blue: 0.16)
    static let logging = Color(red: 0.36, green: 0.66, blue: 0.95)
    static let valueColor = Color(red: 0.72, green: 0.85, blue: 1)

    /// A breakpoint's condition or log message: Luau, set on Return or on leaving the field.
    private struct SettingField: View {
        let text: String
        let placeholder: String
        let help: String
        let color: Color
        let commit: (String) -> Void
        @State private var editing = ""
        @FocusState private var focused: Bool

        var body: some View {
            TextField(placeholder, text: $editing)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(color)
                .focused($focused)
                .onSubmit { commit(editing) }
                .onAppear { editing = text }
                .onChange(of: text) { new in if !focused { editing = new } }
                .onChange(of: focused) { isFocused in if !isFocused { commit(editing) } }
                .help(help)
        }
    }

    // MARK: - Watches and variables

    private var watchList: some View {
        let results = session.debugPause?.watches ?? []
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(session.watchExpressions.enumerated()), id: \.offset) { index, expression in
                    let result = results.first { $0.expression == expression }?.result
                    let opened = "(" + expression + ")"
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        opener(result?.type == "table" && result?.error == nil ? opened : nil)
                        Text(expression)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 130, alignment: .leading)
                            .lineLimit(1)
                        if let result {
                            Text(result.error ?? result.value)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(result.error == nil ? Self.valueColor : Self.warning)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        } else {
                            Text("—").foregroundStyle(Theme.textDim)
                        }
                        Spacer(minLength: 8)
                        if let type = result?.type, result?.error == nil { Text(type).foregroundStyle(Theme.textDim) }
                        Button { session.removeWatch(at: index) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textDim)
                        .help("Stop watching this")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                    if let fields = session.debugOpened[opened] {
                        rows(fields, inside: opened, depth: 1)
                    }
                }
                if session.watchExpressions.isEmpty {
                    Text("Nothing watched: add an expression below, worked out at every stop")
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A disclosure arrow for a table that can open (its expression), or room for one.
    private func opener(_ expression: String?) -> some View {
        Group {
            if let expression {
                Button { session.toggleOpened(expression) } label: {
                    Image(systemName: session.debugOpened[expression] == nil ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textDim)
                .help("Show what's in this table")
            } else {
                Color.clear.frame(width: 10, height: 1)
            }
        }
    }

    /// Variables (or a table's entries), and inside each table opened, its own.
    private func rows(_ variables: [LuauInterpreter.DebugVariable], inside parent: String?, depth: Int) -> AnyView {
        AnyView(ForEach(Array(variables.enumerated()), id: \.offset) { _, variable in
            let expression: String? = variable.path.isEmpty ? nil : (parent ?? "") + variable.path
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                opener(variable.type == "table" ? expression : nil)
                Text(variable.name)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: max(60, 118 - CGFloat(depth) * 12), alignment: .leading)
                    .lineLimit(1)
                Text(variable.value)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Self.valueColor)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                Text(variable.kind == "upvalue" ? "\(variable.type) · upvalue" : variable.type)
                    .foregroundStyle(Theme.textDim)
            }
            .padding(.leading, 10 + CGFloat(depth) * 12)
            .padding(.trailing, 10)
            .padding(.vertical, 2)
            if let expression, let fields = session.debugOpened[expression] {
                if fields.isEmpty {
                    Text("empty").foregroundStyle(Theme.textDim).padding(.leading, 32 + CGFloat(depth) * 12)
                } else {
                    rows(fields, inside: expression, depth: depth + 1)
                }
            }
        })
    }

    private struct Mark: Identifiable {
        let script: ScriptObject
        let line: Int
        var id: String { "\(script.id.uuidString):\(line)" }
    }

    private var variables: some View {
        let frames = session.debugPause?.frames ?? []
        let shown = frames.indices.contains(session.debugFrame) ? frames[session.debugFrame].variables : []
        return ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                if shown.isEmpty {
                    Text(session.debugPause == nil ? "Nothing to show until the game stops" : "No variables here")
                        .foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 10)
                }
                rows(shown, inside: nil, depth: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
