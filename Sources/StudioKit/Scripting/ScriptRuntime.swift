import Foundation
import simd

/// Runs a scene's scripts — Luau and Wren side by side — against the live scene.
///
/// Each language gets its own VM, created only if the scene has scripts in it, and
/// both reach the scene through the same host calls in `invoke` below. Scripts in
/// different languages cannot call each other; they share only the scene itself.
///
/// Luau is primary. Its Roblox-flavoured library (`StudioLibrary.swift`) is loaded
/// first and the VM is sandboxed; each script runs in its own environment inside a
/// thread, so `task.wait` works at the top level; frames are driven through
/// `__studio_tick`; a handler that errors is reported and disconnected; a runaway
/// script is stopped by the watchdog.
///
/// Wren is secondary. Its `studio` and `math` modules (`WrenModules.swift`) are
/// served on import; `Runtime.onUpdate` callbacks run each frame, and an error in
/// one stops Wren's updates. Wren has no watchdog.
final class ScriptRuntime {
    private var interpreter: LuauInterpreter?
    /// What the Luau VM holds, in bytes (`--soak` watches it).
    var luauMemory: Int { interpreter?.memoryUsed ?? 0 }
    private var wren: WrenInterpreter?
    unowned let model: SceneModel
    let console: ScriptConsole

    private(set) var running = false
    private var startTime = Date()
    private var luauFailed = false
    private var wrenFailed = false

    /// True when a frame could not be driven: a Luau library-level failure, or a
    /// Wren update callback that threw (which stops Wren's updates).
    var updateHookFailed: Bool { luauFailed || wrenFailed }

    /// How long one Luau script or handler may run before the watchdog stops it.
    var timeout: Double = 2.0

    /// The play session's player, when there is one. StarterPlayer scripts — the
    /// default ControlScript among them — only run when this is set, and every
    /// `player.*`, `humanoid.*`, `root.*`, `body.*` and `input.*` call goes to it.
    weak var player: PlayerBridge?
    /// Lets scripts ask whether a shader has compiled yet.
    weak var shaderStatus: ShaderStatusStore?
    /// The play session's Sounds, for how long each lasts and where it is.
    weak var soundSystem: SoundSystem?
    /// The play session's clock, in seconds.
    var clock: () -> Double = { 0 }
    /// With no player (Studio's Run mode), where this frame's events come from.
    var eventSource: (() -> [ScriptValue])?
    /// LogService:GetLogHistory — the play session's lines so far, as [message, type, time].
    var logSource: (() -> [ScriptValue])?

    static let libraryChunkName = "StudioLibrary"

    /// Wren scripts run with a two-line prelude, subtracted from reported lines.
    private static let wrenPreludeLines = 2

    init(model: SceneModel, console: ScriptConsole) {
        self.model = model
        self.console = console
    }

    // MARK: - Lifecycle

    /// Builds fresh VMs and runs every enabled script. Safe to call again after
    /// `stop()`: nothing carries over between runs.
    /// False on a player who joined a network game: the host runs the scene's scripts,
    /// and this machine only the player's and character's own.
    var runsSceneScripts = true
    /// PathfindingService's view of the world, brought up to date before each search
    /// (ScriptRuntime+Pathfinding).
    let navigation = NavigationGrid()
    var navigationSyncedAt = -1.0
    /// Luau's debugger, when the session is being debugged (Studio's Play); joins each new VM.
    var debugger: ScriptDebugger?
    /// The Stats service's numbers (`stats.get`): the play session's, as
    /// [frame, scripts, physics, draw ms, memory MB, parts, instances].
    var statsSource: (() -> ScriptValue)?
    /// The play session's NPCs, for `npc.*` (ScriptRuntime+NPC).
    var npcSource: (() -> NPCSystem?)?
    /// ParticleEmitters scripts have made (or cloned, or taken out of a part) and not yet
    /// put in one.
    var looseEmitters: [UUID: ParticleEmitter] = [:]
    /// Skies, Atmospheres and Clouds scripts have made (or taken out of Lighting) and not
    /// yet put there.
    var looseSkyObjects: [UUID: SkyObject] = [:]

    func start() {
        stop()
        startTime = Date()
        luauFailed = false
        wrenFailed = false
        running = true

        // ModuleScripts never run by themselves: scripts require them.
        let enabled = model.scripts.filter { $0.enabled && !$0.isModule }
        // A player who joined a network game leaves the scene's scripts to the host.
        // Scripts in a Tool out of the world wait for it: StarterPack's run in each
        // player's copy, a Backpack's with their character.
        let sceneScripts = runsSceneScripts ? enabled.filter { $0.host == .scene && !model.isParked($0.parentID) } : []
        var playerScripts: [ScriptObject] = []
        var characterScripts: [ScriptObject] = []
        if player != nil {
            // A same-named scene script replaces a core one, even when disabled.
            let overrides = model.scripts
            playerScripts = enabled.filter { $0.host == .starterPlayer }
                + CoreScripts.active(overriddenBy: overrides).filter { $0.host == .starterPlayer }
            characterScripts = startingCharacterScripts()
        }

        let unsupported = (playerScripts + characterScripts).filter { $0.language == .wren }
        for script in unsupported {
            console.warning("\(script.name): Wren scripts in StarterPlayer are not supported yet — Luau gets new features first.")
        }
        playerScripts.removeAll { $0.language == .wren }
        characterScripts.removeAll { $0.language == .wren }

        let luauScene = sceneScripts.filter { $0.language == .luau }
        let wrenScene = sceneScripts.filter { $0.language == .wren }
        let total = luauScene.count + playerScripts.count + characterScripts.count + wrenScene.count
        guard total > 0 else {
            console.info("No scripts in this scene.")
            return
        }

        var failures = 0
        if !luauScene.isEmpty || !playerScripts.isEmpty || !characterScripts.isEmpty {
            if startLuauVM() {
                for script in luauScene + playerScripts {
                    if !spawnLuau(script, scope: 0) { failures += 1 }
                }
                let generation = player?.characterGeneration ?? 0
                if generation > 0 {
                    for script in characterScripts where !spawnLuau(script, scope: generation) {
                        failures += 1
                    }
                }
            } else {
                failures += luauScene.count + playerScripts.count + characterScripts.count
            }
        }
        if !wrenScene.isEmpty { failures += startWren(wrenScene) }

        let ran = total - failures
        console.info("Ran \(ran) script\(ran == 1 ? "" : "s")\(failures > 0 ? ", \(failures) failed" : "").")
    }

    /// StarterCharacterScripts for a new character: the scene's, plus any core ones
    /// not overridden by name.
    private func startingCharacterScripts() -> [ScriptObject] {
        model.scripts.filter { $0.enabled && !$0.isModule && $0.host == .starterCharacter && $0.language == .luau }
            + CoreScripts.active(overriddenBy: model.scripts).filter { $0.host == .starterCharacter }
    }

    private func startLuauVM() -> Bool {
        guard let vm = LuauInterpreter() else {
            console.error("Could not start the Luau VM.")
            return false
        }
        vm.timeout = timeout
        vm.handler = { [weak self] name, arguments in
            self?.invoke(name, arguments) ?? .nothing
        }
        guard vm.run(name: "=" + Self.libraryChunkName, source: studioLibrarySource) else {
            console.error("The script library failed to load: \(vm.lastError)")
            return false
        }
        vm.sandbox()
        interpreter = vm
        debugger?.attach(to: vm, runtime: self)
        for module in model.scripts where module.isModule && module.language == .luau {
            defineModule(module, in: vm)
        }
        return true
    }

    /// Compiles a ModuleScript into a function `require` calls the first time it's asked
    /// for. The wrapper goes on the module's first line, so errors keep its own line
    /// numbers; the module gets its own environment, with `script` as itself.
    private func defineModule(_ module: ScriptObject, in vm: LuauInterpreter) {
        let id = module.id.uuidString
        let environment = "module:\(id)"
        vm.makeEnvironment(environment)
        vm.run(name: "=setup", source: "script, shared, _G = __studio_env_setup(\"\(id)\", 0)", environment: environment)
        let wrapped = "__studio_define_module(\"\(id)\", function(...) " + module.source + "\nend)"
        if !vm.run(name: "=" + module.name, source: wrapped, environment: environment) {
            // The module won't load; requiring it says so, and here is why.
            console.error(vm.lastError)
        }
    }

    /// Runs one Luau script in its own environment. `scope` is 0 for scripts that
    /// live for the whole session, or the character generation for character
    /// scripts — everything they start is stopped when that character goes.
    private func spawnLuau(_ script: ScriptObject, scope: Int) -> Bool {
        guard let vm = interpreter else { return false }
        let environment = "script:\(script.id.uuidString):\(scope)"
        vm.makeEnvironment(environment)
        vm.run(name: "=setup",
               source: "script, shared, _G = __studio_env_setup(\"\(script.id.uuidString)\", \(scope))",
               environment: environment)
        vm.callGlobal("__studio_set_spawn_scope", argument: Double(scope))
        vm.callGlobal("__studio_set_spawn_local", argument: script.host == .scene ? 0 : 1)
        // "=" makes the chunk name print verbatim: errors read `Name:12: …`
        // against the user's own lines, with nothing prepended.
        let ok = vm.spawn(name: "=" + script.name, source: script.source, environment: environment)
        // Read before the next call into the VM clears it.
        let problem = ok ? "" : vm.lastError
        vm.callGlobal("__studio_set_spawn_scope", argument: 0)
        vm.callGlobal("__studio_set_spawn_local", argument: 0)
        if !problem.isEmpty {
            // Compile errors come back here; runtime errors were already reported.
            console.error(problem)
        }
        return ok
    }

    /// A character was replaced: stop everything the old one's scripts started, then
    /// run StarterCharacterScripts again for the new one — as Roblox does.
    func characterRespawned(from previous: Int, to next: Int) {
        guard running, let vm = interpreter ?? (startLuauVM() ? interpreter : nil) else { return }
        if previous > 0 {
            vm.callGlobal("__studio_kill_scope", argument: Double(previous))
            for script in startingCharacterScripts() {
                vm.dropEnvironment("script:\(script.id.uuidString):\(previous)")
            }
        }
        for script in startingCharacterScripts() {
            _ = spawnLuau(script, scope: next)
        }
    }

    /// Starts scripts that arrive mid-game — the scripts in a copy of a StarterPack
    /// tool — under a scope that ends with the character they came with. Luau only.
    func runScripts(_ scripts: [ScriptObject], scope: Int) {
        guard running, !scripts.isEmpty, interpreter != nil || startLuauVM() else { return }
        for script in scripts where script.enabled {
            if script.language == .wren {
                console.warning("\(script.name): Wren scripts in tools are not supported yet — Luau gets new features first.")
                continue
            }
            _ = spawnLuau(script, scope: scope)
        }
    }

    /// Ends a scope started with `runScripts`: its threads and connections stop.
    func endScope(_ scope: Int, scripts: [ScriptObject]) {
        guard running, let vm = interpreter else { return }
        vm.callGlobal("__studio_kill_scope", argument: Double(scope))
        for script in scripts {
            vm.dropEnvironment("script:\(script.id.uuidString):\(scope)")
        }
    }

    /// Returns how many scripts failed to start.
    private func startWren(_ scripts: [ScriptObject]) -> Int {
        let vm = WrenInterpreter()
        vm.lineOffset = Self.wrenPreludeLines
        vm.moduleLoader = { name in
            switch name {
            case "studio": return wrenStudioModuleSource
            case "math": return wrenMathModuleSource
            default: return nil
            }
        }
        vm.onOutput = { [console] output in
            switch output {
            case .print(let text): console.output(text)
            case .error(let text): console.error(text)
            }
        }
        vm.handler = { [weak self] name, arguments in
            self?.invoke(name, arguments) ?? .nothing
        }
        wren = vm

        var usedModules: Set<String> = []
        var failures = 0
        for script in scripts {
            var moduleName = script.name
            var suffix = 2
            while usedModules.contains(moduleName) {
                moduleName = "\(script.name)#\(suffix)"
                suffix += 1
            }
            usedModules.insert(moduleName)

            // Wren reserves leading double underscores for static fields, so the
            // alias the prelude imports under cannot use them.
            let prelude = """
            import "studio" for Script as StudioScript_
            var script = StudioScript_.forId_("\(script.id.uuidString)")
            """
            if !vm.interpret(module: moduleName, source: prelude + "\n" + script.source) {
                failures += 1
            }
        }
        return failures
    }

    func stop() {
        running = false
        interpreter = nil
        wren = nil
    }

    func update(dt: Double) {
        guard running else { return }
        if let vm = interpreter, !vm.callGlobal("__studio_tick", argument: dt) {
            luauFailed = true
            console.error(vm.lastError)
        }
        if let vm = wren, !wrenFailed, !vm.tick(dt: dt) {
            wrenFailed = true
            console.error("Wren update callbacks stopped after an error.")
        }
    }

    var elapsed: Double { Date().timeIntervalSince(startTime) }

    var memoryUsed: Int { interpreter?.memoryUsed ?? 0 }

    /// Error text plus the user's own stack frames — the library's frames are noise.
    private func reportError(_ message: String, trace: String) {
        console.error(message)
        let frames = trace
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(Self.libraryChunkName) && !$0.hasPrefix("[C]") }
        for frame in frames.prefix(6) {
            console.error("    " + frame)
        }
    }

    // MARK: - Host API

    /// Every call the scripts make to the host lands here and goes to the handler for
    /// the part of its name before the dot — `part.get` to `partsCall` — each in its own
    /// `ScriptRuntime+….swift` file. The player's own namespaces go to the play session.
    func invoke(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        let namespace = name.split(separator: ".", maxSplits: 1).first.map(String.init) ?? name
        // Everything about the player and its character is answered by the play
        // session (PlayerHost.swift); with no session there is no character.
        if PlayerHost.namespaces.contains(namespace) {
            // Run mode has no player but still has events: touches, Sounds ending.
            if player == nil, name == "player.events", let eventSource { return .list(eventSource()) }
            return player?.playerInvoke(name, arguments) ?? PlayerHost.withoutPlayer(name, arguments)
        }
        switch namespace {
        case "light", "lighting", "click": return lightingCall(name, arguments)
        case "sound": return soundCall(name, arguments)
        case "log": return .list(logSource?() ?? [])
        case "animation": return animationsCall(name, arguments)
        case "tree", "node", "group", "tool": return treeCall(name, arguments)
        case "attachment", "constraint": return jointsCall(name, arguments)
        case "workspace" where name == "workspace.raycast": return raycast(arguments)
        case "part", "workspace": return partsCall(name, arguments)
        case "data": return dataCall(name, arguments)
        case "datastore": return dataStoreCall(name, arguments)
        case "path": return pathCall(name, arguments)
        case "stats": return statsSource?() ?? .list([])
        case "npc": return npcCall(name, arguments)
        case "emitter": return emitterCall(name, arguments)
        case "ribbon": return ribbonCall(name, arguments)
        case "sky": return skyCall(name, arguments)
        case "module": return moduleCall(name, arguments)
        case "shader", "screen": return shadersCall(name, arguments)
        case "runtime", "script": return runtimeCall(name, arguments)
        default: return unknownCall(name)
        }
    }

    /// A call no handler knows: a name mistyped between the library and the host.
    func unknownCall(_ name: String) -> ScriptValue {
        console.error("Unknown host call \"\(name)\".")
        return .nothing
    }

    /// Host calls for `runtime.*` and `script.*`: time, logging and scripts themselves.
    func runtimeCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        case "runtime.print":
            console.output(arguments.first?.asString ?? "")
            return .nothing

        case "runtime.warn":
            console.warning(arguments.first?.asString ?? "")
            return .nothing

        case "runtime.log":   // Wren
            console.output(arguments.first?.asString ?? "")
            return .nothing

        case "runtime.time":  // Wren; Luau keeps its own clock
            return .number(elapsed)

        case "runtime.error":
            reportError(arguments.first?.asString ?? "error",
                        trace: arguments.count > 1 ? (arguments[1].asString ?? "") : "")
            return .nothing

        case "script.get":
            guard arguments.count >= 2, let string = arguments[0].asString,
                  let id = UUID(uuidString: string),
                  let script = model.script(id: id) ?? CoreScripts.script(id: id) else { return .nothing }
            switch arguments[1].asString {
            case "name": return .string(script.name)
            case "class":
                return .string(script.isModule ? "ModuleScript" : script.host == .scene ? "Script" : "LocalScript")
            default: return .nothing
            }

        case "script.parent":
            guard let string = arguments.first?.asString, let id = UUID(uuidString: string),
                  let script = model.script(id: id), let parent = script.parentID,
                  model.index(of: parent) != nil else { return .nothing }
            return .string(parent.uuidString)

        default:
            return unknownCall(name)
        }
    }

    // MARK: - Lighting

    func uuid(_ value: ScriptValue?) -> UUID? {
        value?.asString.flatMap(UUID.init(uuidString:))
    }

}
