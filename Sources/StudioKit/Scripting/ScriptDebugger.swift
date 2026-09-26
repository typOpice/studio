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
    }

    struct Pause: Equatable {
        var reason: Reason
        /// The calls in scripts, innermost first (the library's own are left out).
        var frames: [Frame]
    }

    /// What to do at a stop: the answer lets the scripts go on. Studio asks the person
    /// (in a nested event loop); tests answer at once.
    var handler: ((Pause) -> Command)?
    /// Where it's stopped, while it is.
    private(set) var paused: Pause?
    /// Stop was chosen: no more stops, and the session ends.
    private(set) var stopRequested = false

    private weak var runtime: ScriptRuntime?
    private weak var vm: LuauInterpreter?
    /// Each script's breakpoints as they landed (a line with no code moves to the next).
    private var landed: [UUID: Set<Int>] = [:]
    private var stepping: (mode: Command, thread: UnsafeRawPointer?, depth: Int)?

    init(handler: ((Pause) -> Command)? = nil) {
        self.handler = handler
    }

    /// Joins a runtime's new VM.
    func attach(to vm: LuauInterpreter, runtime: ScriptRuntime) {
        self.vm = vm
        self.runtime = runtime
        landed = [:]
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
        for line in script.breakpoints {
            let at = vm.setBreakpoint(key: id.uuidString, line: line, enabled: true)
            if at > 0 { landed[id, default: []].insert(at) }
        }
    }

    /// A breakpoint put on or taken off while the scripts run.
    func setBreakpoint(script id: UUID, line: Int, on: Bool) {
        guard let vm else { return }
        let at = vm.setBreakpoint(key: id.uuidString, line: line, enabled: on)
        guard at > 0 else { return }
        if on {
            landed[id, default: []].insert(at)
        } else {
            landed[id]?.remove(at)
            // Another breakpoint may have landed on the same line.
            for other in runtime?.model.script(id: id)?.breakpoints ?? [] where other != line {
                let again = vm.setBreakpoint(key: id.uuidString, line: other, enabled: true)
                if again > 0 { landed[id, default: []].insert(again) }
            }
        }
    }

    // MARK: - Stopping

    private func reached(_ line: Int) {
        guard let vm, let handler, !stopRequested, let top = vm.frame(0) else { return }
        let id = Self.scriptID(inEnvironment: top.environment)
        let isBreakpoint = id.map { landed[$0]?.contains(line) == true } ?? false
        let thread = vm.pausedThread
        let depth = vm.pausedDepth
        var reason = Reason.breakpoint
        if let step = stepping {
            // A step stops at the next line in the same thread: any, for Step Into; no
            // deeper, for Step Over; shallower, for Step Out. A breakpoint stops anyway.
            let here = thread == step.thread
            let wanted: Bool
            switch step.mode {
            case .stepInto: wanted = here && id != nil
            case .stepOver: wanted = here && depth <= step.depth
            case .stepOut: wanted = here && depth < step.depth
            default: wanted = false
            }
            guard wanted || isBreakpoint else { return }
            if !isBreakpoint { reason = .step }
            endStepping()
        } else if !isBreakpoint {
            return
        }

        let pause = Pause(reason: reason, frames: frames(depth: depth))
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
                              variables: vm.variables(at: level)))
        }
        return list
    }
}
