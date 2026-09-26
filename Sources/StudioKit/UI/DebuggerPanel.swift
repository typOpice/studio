import SwiftUI

/// The Debugger tab: while the scripts are stopped at a breakpoint, where (the calls,
/// innermost first — pick one to see its variables and its line) and what each
/// variable holds, with Continue, Step Over, Step Into, Step Out and Stop; and always,
/// the place's breakpoints. Breakpoints are set by clicking beside a line number.
struct DebuggerPanel: View {
    @ObservedObject var model: SceneModel
    @ObservedObject var session: EditorSession

    var body: some View {
        VStack(spacing: 0) {
            controls
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
                    HStack(spacing: 6) {
                        Circle().fill(Color(red: 0.9, green: 0.3, blue: 0.3)).frame(width: 7, height: 7)
                        Button { session.openScript(script.id, line: line) } label: {
                            Text("\(script.name):\(line)")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        Button { session.toggleBreakpoint(script: script.id, line: line) } label: {
                            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textDim)
                        .help("Remove this breakpoint")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: 110)
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
                ForEach(Array(shown.enumerated()), id: \.offset) { _, variable in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(variable.name)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 130, alignment: .leading)
                            .lineLimit(1)
                        Text(variable.value)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color(red: 0.72, green: 0.85, blue: 1))
                            .lineLimit(2)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Text(variable.kind == "upvalue" ? "\(variable.type) · upvalue" : variable.type)
                            .foregroundStyle(Theme.textDim)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
