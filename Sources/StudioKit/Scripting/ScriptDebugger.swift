import Foundation

/// The Luau debugger for one play session: stops at the scripts' breakpoints with every
/// script frozen, shows where (the calls, from the line it stopped at out to the
/// script's own code) and what each call's variables hold, then goes on — to the next
/// breakpoint, or a step: over the line, into what it calls, or out of the function.
///
/// Breakpoints are Luau's own, put on every chunk of a script as it loads (a character
/// script loads again for every character). A step is a breakpoint on every line of
/// every script, taken away at the next stop; stops in other threads, or deeper than a
/// step over wants, are passed over. See LuauInterpreter's debugger calls and the shim.
///
/// A breakpoint may have a condition, a Luau expression worked out in the stopped call
/// (its locals, then its upvalues, then the script's globals): it stops only when that
/// holds, or when it fails (to say why). One with a log message is a logpoint: it
/// prints the message (worked out the same way) and goes on. Each counts its hits.
/// Watch expressions are worked out at every stop, and while stopped any expression
/// can be, and any table opened.
final class ScriptDebugger {
    enum Command: Equatable { case resume, stepOver, stepInto, stepOut, stop }
    enum Reason: Equatable { case breakpoint, step }

    /// A call in a script: where, and what its variables hold.
    struct Frame: Equatable {
        var scriptID: UUID?
        var script: String
        var function: String
        var line: Int
        var variables: [LuauInterpreter.DebugVariable]
        /// Where it is on the VM's stack, to work expressions out in it.
        var level = 0
    }

    /// A watch expression, and what it came to.
    struct Watch: Equatable {
        var expression: String
        var result: LuauInterpreter.Evaluation
    }

    struct Pause: Equatable {
        var reason: Reason
        /// The calls in scripts, innermost first (the library's own are left out).
        var frames: [Frame]
        /// The watch expressions, worked out in the innermost call.
        var watches: [Watch] = []
        /// Anything else to know: that the breakpoint's condition failed, and why.
        var note: String?
    }

    /// Expressions worked out at every stop (Pause.watches).
    var watches: [String] = []

    /// What to do at a stop: the answer lets the scripts go on. Studio asks the person
    /// (in a nested event loop); tests answer at once.
    var handler: ((Pause) -> Command)?
    /// Where it's stopped, while it is.
    private(set) var paused: Pause?
    /// Stop was chosen: no more stops, and the session ends.
    private(set) var stopRequested = false

    private weak var runtime: ScriptRuntime?
    private weak var vm: LuauInterpreter?
    /// Each script's breakpoints as they landed (a line with no code moves to the next),
    /// and what each one there asks: several can land on one line.
    private var landed: [UUID: Set<Int>] = [:]
    private var rules: [UUID: [Int: [Rule]]] = [:]
    /// How many times each breakpoint's line has run, by the line it was put on.
    private(set) var hits: [UUID: [Int: Int]] = [:]
    /// A breakpoint's line ran (for a live count of hits).
    var onHit: (() -> Void)?

    /// A breakpoint as it landed: the line it was put on, and its condition and message.
    private struct Rule {
        var line: Int
        var condition: String?
        var log: String?
    }
    private var stepping: (mode: Command, thread: UnsafeRawPointer?, depth: Int)?

    init(handler: ((Pause) -> Command)? = nil) {
        self.handler = handler
    }

    /// Joins a runtime's new VM.
    func attach(to vm: LuauInterpreter, runtime: ScriptRuntime) {
        self.vm = vm
        self.runtime = runtime
        landed = [:]
        rules = [:]
        stepping = nil
        vm.attachDebugger()
        vm.onLoaded = { [weak self] environment in self?.loaded(environment) }
        vm.onPause = { [weak self] line in self?.reached(line) }
    }

    /// The script an environment belongs to: "script:<id>:<scope>" or "module:<id>".
    static func scriptID(inEnvironment environment: String) -> UUID? {
        let parts = environment.split(separator: ":")
        guard parts.count >= 2, parts[0] == "script" || parts[0] == "module" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    private func loaded(_ environment: String) {
        guard let vm, let id = Self.scriptID(inEnvironment: environment),
              let script = runtime?.model.script(id: id) else { return }
        vm.keepChunk(key: id.uuidString)
        land(script)
    }

    /// Puts a script's breakpoints on its chunks, noting where they landed and what each
    /// asks there.
    private func land(_ script: ScriptObject) {
        guard let vm else { return }
        var lines: Set<Int> = [], found: [Int: [Rule]] = [:]
        for line in script.breakpoints {
            let at = vm.setBreakpoint(key: script.id.uuidString, line: line, enabled: true)
            guard at > 0 else { continue }
            lines.insert(at)
            found[at, default: []].append(Rule(line: line, condition: script.breakpointConditions[line],
                                               log: script.breakpointLogs[line]))
        }
        landed[script.id] = lines.isEmpty ? nil : lines
        rules[script.id] = found.isEmpty ? nil : found
    }

    /// How many times a breakpoint's line has run this session.
    func hits(script id: UUID, line: Int) -> Int { hits[id]?[line] ?? 0 }

    /// A breakpoint put on or taken off while the scripts run.
    func setBreakpoint(script id: UUID, line: Int, on: Bool) {
        guard let vm else { return }
        if !on {
            // Off where it landed; any other breakpoint that landed there goes back on.
            vm.setBreakpoint(key: id.uuidString, line: line, enabled: false)
        }
        breakpointsChanged(script: id)
        if on {
            // On even if the script's breakpoints don't have it yet.
            let at = vm.setBreakpoint(key: id.uuidString, line: line, enabled: true)
            if at > 0 { landed[id, default: []].insert(at) }
        }
    }

    /// A script's breakpoints or their conditions changed while the scripts run.
    func breakpointsChanged(script id: UUID) {
        guard let script = runtime?.model.script(id: id) else { return }
        if script.breakpoints.isEmpty {
            landed[id] = nil
            rules[id] = nil
        } else {
            land(script)
        }
    }

    // MARK: - Stopping

    private func reached(_ line: Int) {
        guard let vm, let handler, !stopRequested, let top = vm.frame(0) else { return }
        let id = Self.scriptID(inEnvironment: top.environment)
        var isBreakpoint = id.map { landed[$0]?.contains(line) == true } ?? false
        let thread = vm.pausedThread
        let depth = vm.pausedDepth
        var wanted = false
        if let step = stepping {
            // A step stops at the next line in the same thread: any, for Step Into; no
            // deeper, for Step Over; shallower, for Step Out. A breakpoint stops anyway.
            let here = thread == step.thread
            switch step.mode {
            case .stepInto: wanted = here && id != nil
            case .stepOver: wanted = here && depth <= step.depth
            case .stepOut: wanted = here && depth < step.depth
            default: wanted = false
            }
        }
        // Each breakpoint here: a condition that doesn't hold passes it over, and one that
        // fails stops, to say so; a logpoint prints and goes on; the rest stop.
        var note: String?
        if isBreakpoint, let id {
            var stops = false
            for rule in rules[id]?[line] ?? [Rule(line: line)] {
                hits[id, default: [:]][rule.line, default: 0] += 1
                if let condition = rule.condition {
                    let result = vm.evaluate(condition, at: 0)
                    if let error = result.error {
                        note = "The breakpoint's condition (\(condition)) failed: \(error)"
                        stops = true
                        continue
                    }
                    guard result.truthy else { continue }
                }
                if let log = rule.log {
                    let message = vm.logMessage(log, at: 0)
                    if let error = message.error {
                        runtime?.console.error("Logpoint at \(runtime?.model.script(id: id)?.name ?? "Script"):\(rule.line): \(error)")
                    } else {
                        runtime?.console.output(message.value)
                    }
                } else {
                    stops = true
                }
            }
            isBreakpoint = stops
            onHit?()
        }
        guard wanted || isBreakpoint else { return }
        if stepping != nil { endStepping() }

        let frames = frames(depth: depth)
        let level = frames.first?.level ?? 0
        let pause = Pause(reason: isBreakpoint ? .breakpoint : .step, frames: frames,
                          watches: watches.map { Watch(expression: $0, result: vm.evaluate($0, at: level)) },
                          note: note)
        paused = pause
        let command = handler(pause)
        paused = nil
        switch command {
        case .resume:
            break
        case .stop:
            stopRequested = true
            landed = [:]
            vm.breakEverywhere(false)
        case .stepOver, .stepInto, .stepOut:
            stepping = (command, thread, depth)
            vm.breakEverywhere(true)
        }
    }

    /// Takes the stepping breakpoints away, and puts the scripts' own back.
    private func endStepping() {
        stepping = nil
        guard let vm else { return }
        vm.breakEverywhere(false)
        for (id, lines) in landed {
            for line in lines { vm.setBreakpoint(key: id.uuidString, line: line, enabled: true) }
        }
    }

    private func frames(depth: Int) -> [Frame] {
        guard let vm else { return [] }
        var list: [Frame] = []
        for level in 0..<max(depth, 1) {
            guard let frame = vm.frame(level) else { break }
            guard let id = Self.scriptID(inEnvironment: frame.environment) else { continue }
            let name = runtime?.model.script(id: id)?.name ?? "Script"
            list.append(Frame(scriptID: id, script: name, function: frame.function, line: frame.line,
                              variables: vm.variables(at: level), level: level))
        }
        return list
    }

    // MARK: - While stopped

    /// An expression worked out in one of the stop's calls (by its place in Pause.frames).
    func evaluate(_ expression: String, inFrame index: Int = 0) -> LuauInterpreter.Evaluation {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let vm, let pause = paused else { return LuauInterpreter.Evaluation(error: "not stopped") }
        guard !trimmed.isEmpty else { return LuauInterpreter.Evaluation(error: "nothing to work out") }
        return vm.evaluate(trimmed, at: level(of: index, in: pause))
    }

    /// What's in the table an expression comes to (a variable's path, or one inside it:
    /// `stats.best`, `list[2]`), numbered entries first, then by name; nil if it isn't one.
    func fields(of expression: String, inFrame index: Int = 0) -> [LuauInterpreter.DebugVariable]? {
        guard let vm, let pause = paused else { return nil }
        return vm.fields(of: expression, at: level(of: index, in: pause)).map(Self.ordered)
    }

    private func level(of index: Int, in pause: Pause) -> Int {
        pause.frames.indices.contains(index) ? pause.frames[index].level : (pause.frames.first?.level ?? 0)
    }

    static func ordered(_ fields: [LuauInterpreter.DebugVariable]) -> [LuauInterpreter.DebugVariable] {
        func number(_ field: LuauInterpreter.DebugVariable) -> Double? {
            field.path.hasPrefix("[") && !field.path.hasPrefix("[\"") ? Double(field.path.dropFirst().dropLast()) : nil
        }
        return fields.sorted { a, b in
            switch (number(a), number(b)) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}
