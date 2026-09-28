import Foundation
import Combine
import AppKit

/// What the bottom panel shows: the console, or the Animation Editor's timeline.
/// Scripts and shaders are not here — they open in tabs beside the world.
enum DockTab: String, CaseIterable, Identifiable {
    case output, animation, debugger, terrain, toolbox

    var id: String { rawValue }

    var title: String {
        switch self {
        case .output: return "Output"
        case .animation: return "Animation"
        case .debugger: return "Debugger"
        case .terrain: return "Terrain"
        case .toolbox: return "Toolbox"
        }
    }

    var symbolName: String {
        switch self {
        case .output: return "text.alignleft"
        case .animation: return "figure.walk"
        case .debugger: return "ladybug"
        case .terrain: return "mountain.2"
        case .toolbox: return "shippingbox"
        }
    }
}

/// Something open in a tab beside the world, as scripts are in Roblox Studio: a
/// script or shader being edited, or one of the built-in scripts being read.
enum EditorDocument: Hashable, Identifiable {
    case script(UUID)
    case shader(UUID)
    /// A built-in StarterPlayer script, by name. Read-only.
    case coreScript(String)

    var id: String {
        switch self {
        case .script(let id): return "script:\(id.uuidString)"
        case .shader(let id): return "shader:\(id.uuidString)"
        case .coreScript(let name): return "core:\(name)"
        }
    }
}

/// A line to bring into view in a script tab — where an error in the Output happened.
/// The token tells one request from the next, so asking for the same line twice
/// still scrolls there twice.
struct CodeReveal: Equatable {
    let document: EditorDocument
    let line: Int
    let token = UUID()
}

/// Owns the editor's viewport, its play-test session and the tabs: the world and every
/// open script or shader. Entering play mode snapshots the scene so stopping restores
/// exactly what was there, like Roblox Studio.
final class EditorSession: ObservableObject {
    let model: SceneModel
    let viewport: ViewportController
    let console = ScriptConsole()
    let shaderStatus = ShaderStatusStore()
    /// Each open tab's text view, kept while another tab is in front.
    let codeViews = CodeEditorCache()

    @Published private(set) var play: PlayController?
    @Published var dockTab: DockTab = .output
    /// The console sits along the bottom from the start.
    @Published var dockVisible = true
    /// How tall the bottom panel is, in points; dragged by its top edge.
    @Published var dockHeight: CGFloat = 200
    /// Which set of ribbon groups is showing.
    @Published var ribbonTab: RibbonTab = .home
    /// The home page is showing instead of the editor: at launch, and File › Home.
    @Published var showingHome = false
    let home = HomeModel()

    /// Open scripts and shaders, in the order their tabs were opened.
    @Published private(set) var documents: [EditorDocument] = []
    /// The tab in front; nil is the world.
    @Published private(set) var activeDocument: EditorDocument?
    /// The latest request to show a line, from clicking an error in the Output.
    @Published private(set) var revealRequest: CodeReveal?

    private var snapshot = SceneState()
    private var watchers: [AnyCancellable] = []
    /// StarterGui as it will look, drawn over the editor's viewport, the selected object
    /// outlined; rebuilt whenever StarterGui changes.
    let guiPreview = GuiStore()
    @Published var showsGuiPreview = true
    /// Editing that preview from the GUI tab: devices, dragging, snapping, the buttons.
    private(set) lazy var guiEditor = GuiEditController(model: model, store: guiPreview)

    /// The GUI tab is open over the world, outside play: StarterGui can be clicked and dragged.
    var editingGui: Bool { ribbonTab == .gui && !isPlaying && showsWorld && showsGuiPreview }

    /// Esc, anywhere in the editor: nothing selected at all. The animation in the Animation
    /// tab stays open while that tab is showing. True when it did something.
    @discardableResult
    func deselectAll() -> Bool {
        let keepAnimation = dockVisible && dockTab == .animation
        let any = model.hasAnySelection || (!keepAnimation && model.selectedAnimation != nil)
        model.deselectAll(keepingAnimation: keepAnimation)
        guiEditor.hover(at: nil)
        if any { model.statusText = "Deselected everything" }
        return any
    }

    /// A key the editor's window is about to handle: Esc (with no modifiers, outside play)
    /// deselects everything first, wherever the keyboard is — then goes on to wherever it
    /// was going, so a text field still cancels and the code editor still closes its list.
    func handleEscape(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard keyCode == 53, modifiers.intersection([.command, .option, .control, .shift]).isEmpty,
              !isPlaying else { return }
        deselectAll()
    }

    /// What the editor window's key monitor does with a key before anything else sees it:
    /// Esc in that window deselects everything; every key then goes on as it would.
    func monitorKey(_ event: NSEvent, editorWindow: NSWindow?) -> NSEvent {
        if event.type == .keyDown, let editorWindow, event.window === editorWindow {
            handleEscape(keyCode: event.keyCode, modifiers: event.modifierFlags)
        }
        return event
    }

    /// The arrows nudge the selected GUI object (Shift: ten pixels); Escape lets go of it.
    private func guiKey(_ keyCode: UInt16, shift: Bool) -> Bool {
        guard editingGui, model.selection.isEmpty, model.selectedGui != nil else { return false }
        let step: CGFloat = shift ? 10 : 1
        switch keyCode {
        case 123: guiEditor.nudge(dx: -step, dy: 0)
        case 124: guiEditor.nudge(dx: step, dy: 0)
        case 125: guiEditor.nudge(dx: 0, dy: step)
        case 126: guiEditor.nudge(dx: 0, dy: -step)
        case 53: model.selectedGui = nil
        default: return false
        }
        return true
    }
    /// Listening to a sound asset from its properties, in the editor.
    lazy var previewSounds = SoundSystem()
    private var previewPictures: [UUID: (size: Int, image: NSImage)] = [:]

    func preview(_ asset: SceneAsset) {
        stopPreview()
        guard let buffer = previewSounds.buffer(for: asset) else { return }
        previewSounds.output.start(asset.id, buffer: buffer, from: 0, looped: false, volume: 1, speed: 1, at: nil)
        previewing = asset.id
    }

    func stopPreview() {
        if let previewing { previewSounds.output.stop(previewing) }
        previewing = nil
    }
    private var previewing: UUID?

    /// A picture for the StarterGui preview's ImageLabels.
    private func picture(named reference: String) -> NSImage? {
        guard let asset = model.asset(named: reference), asset.kind == .image else { return nil }
        if let known = previewPictures[asset.id], known.size == asset.data.count { return known.image }
        guard let image = NSImage(data: asset.data) else { return nil }
        previewPictures[asset.id] = (asset.data.count, image)
        return image
    }

    init(model: SceneModel) {
        self.model = model
        self.viewport = ViewportController(model: model, shaderStatus: shaderStatus, console: console)
        // A script or shader that goes — deleted, undone, or a different scene opened —
        // takes its tab with it. `@Published` hands over the new value before storing it.
        watchers.append(model.$scripts.sink { [weak self] scripts in
            let live = Set(scripts.map(\.id))
            self?.closeDocuments { if case .script(let id) = $0 { return !live.contains(id) } else { return false } }
        })
        guiPreview.imageProvider = { [weak self] reference in self?.picture(named: reference) }
        viewport.guiKeys = { [weak self] code, shift in self?.guiKey(code, shift: shift) ?? false }
        watchers.append(model.$starterGui.combineLatest(model.$selectedGui).sink { [weak self] templates, selected in
            self?.rebuildGuiPreview(templates, selected: selected)
        })
        watchers.append(model.$shaders.sink { [weak self] shaders in
            let live = Set(shaders.map(\.id))
            self?.closeDocuments { if case .shader(let id) = $0 { return !live.contains(id) } else { return false } }
        })
    }

    /// Playing or running: scripts are going and the scene will be put back on Stop.
    private func rebuildGuiPreview(_ templates: [StarterGuiObject], selected: UUID?) {
        guiPreview.removeAll()
        var copies: [UUID: Int] = [:]
        for screen in templates where screen.parentID == nil && screen.kind == .screenGui {
            copies.merge(guiPreview.copy(screen, from: templates, into: GuiStore.playerGui)) { first, _ in first }
        }
        guiPreview.highlighted = selected.flatMap { copies[$0] }
        guiEditor.copies = copies
    }

    var isPlaying: Bool { play != nil }
    /// True in Run mode (F8): the scene's scripts and physics with no player, seen through
    /// the editor's camera, as in Roblox Studio.
    @Published private(set) var isRunMode = false

    /// The session that takes the viewport's mouse and keys: the player's, never Run mode's.
    var player: PlayController? { isRunMode ? nil : play }

    /// The renderer's current frame source: the play session while testing, otherwise the editor.
    var source: ViewportSource { player ?? viewport }

    func startPlay() { begin(withPlayer: true) }

    /// Runs the scene's scripts and physics without a player; the editor keeps the camera.
    func startRun() { begin(withPlayer: false) }

    private func begin(withPlayer: Bool) {
        guard play == nil else { return }
        snapshot = model.state
        model.selection = []
        // Play shows the game, whichever tab was in front.
        showWorld()
        console.clear()
        console.info(withPlayer ? "▶ Play started" : "▶ Run started — scripts and physics, no player")
        let controller = PlayController(model: model, console: console, shaderStatus: shaderStatus,
                                        withPlayer: withPlayer)
        // Luau's debugger: stops at breakpoints, and asks here what next.
        let debugger = ScriptDebugger { [weak self] pause in self?.paused(pause) ?? .resume }
        debugger.watches = model.watches
        debugger.onHit = { [weak self] in self?.hitsChanged() }
        breakpointHits = [:]
        controller.scripts.debugger = debugger
        controller.onDebuggerStop = { [weak self] in
            DispatchQueue.main.async { self?.stopPlay() }
        }
        isRunMode = !withPlayer
        play = controller
        if !withPlayer { viewport.running = controller }
        controller.start()
        dockTab = .output
        dockVisible = true
        model.statusText = withPlayer ? "Playing — press Escape to release the mouse, Stop to return"
                                      : "Running — Stop (F8) puts the scene back"
    }

    func stopPlay() {
        guard let controller = play else { return }
        // Stopped at a breakpoint the scripts are mid-run: let them go, then stop.
        if debugPause != nil {
            debugCommand = .stop
            return
        }
        let wasRunning = isRunMode
        controller.stop()
        viewport.running = nil
        play = nil
        isRunMode = false
        // Scripts edit the live scene, so restore what was there before play began —
        // but not the breakpoints, which aren't the game's.
        let breakpoints = model.scripts.map { ($0.id, $0.breakpoints, $0.breakpointConditions, $0.breakpointLogs) }
        let watches = model.watches
        model.state = snapshot
        for (id, lines, conditions, logs) in breakpoints {
            model.setBreakpoints(lines, conditions: conditions, logs: logs, forScript: id)
        }
        model.setWatches(watches)
        console.info(wasRunning ? "■ Run stopped — scene restored" : "■ Play stopped — scene restored")
        model.statusText = "Stopped — scene restored"
    }

    func toggleRun() {
        isPlaying ? stopPlay() : startRun()
    }

    // MARK: - The debugger

    /// Where the scripts are stopped at a breakpoint, while they are.
    @Published private(set) var debugPause: ScriptDebugger.Pause?
    /// The call whose variables the Debugger panel shows.
    @Published var debugFrame = 0
    private var debugCommand: ScriptDebugger.Command?
    /// Expressions the Debugger panel works out at every stop: the place's.
    var watchExpressions: [String] { model.watches }
    /// How many times each breakpoint's line has run in the last play, by script and line.
    @Published private(set) var breakpointHits: [UUID: [Int: Int]] = [:]
    private var hitsPending = false
    /// While stopped: the tables opened in the Debugger panel, by their expressions
    /// ("stats", "stats.best", "(watch)"), and what's in them.
    @Published private(set) var debugOpened: [String: [LuauInterpreter.DebugVariable]] = [:]

    private var debugger: ScriptDebugger? { play?.scripts.debugger }

    func addWatch(_ expression: String) {
        let trimmed = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.setWatches(model.watches + [trimmed])
        watchesChanged()
    }

    func removeWatch(at index: Int) {
        guard model.watches.indices.contains(index) else { return }
        var watches = model.watches
        watches.remove(at: index)
        model.setWatches(watches)
        watchesChanged()
    }

    private func watchesChanged() {
        debugger?.watches = watchExpressions
        rewatch()
    }

    /// The hit counts shown, a few times a second at most while the game runs.
    private func hitsChanged() {
        guard !hitsPending else { return }
        hitsPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.hitsPending = false
            if let hits = self.debugger?.hits, hits != self.breakpointHits { self.breakpointHits = hits }
        }
    }

    /// The watches again, in the call shown.
    private func rewatch() {
        guard let debugger, debugPause != nil else { return }
        debugPause?.watches = watchExpressions.map {
            ScriptDebugger.Watch(expression: $0, result: debugger.evaluate($0, inFrame: debugFrame))
        }
    }

    /// Opens a table in the Debugger panel (its expression), or closes it.
    func toggleOpened(_ expression: String) {
        if debugOpened[expression] != nil {
            // It, and the tables opened inside it.
            debugOpened = debugOpened.filter { key, _ in
                key != expression && !key.hasPrefix(expression + ".") && !key.hasPrefix(expression + "[")
            }
        } else if let fields = debugger?.fields(of: expression, inFrame: debugFrame) {
            debugOpened[expression] = fields
        }
    }

    /// A breakpoint's condition — in the running game too.
    func setBreakpointCondition(script id: UUID, line: Int, _ condition: String) {
        model.setBreakpointCondition(condition, line: line, forScript: id)
        debugger?.breakpointsChanged(script: id)
    }

    /// A breakpoint's log message, making it a logpoint — in the running game too.
    func setBreakpointLog(script id: UUID, line: Int, _ message: String) {
        model.setBreakpointLog(message, line: line, forScript: id)
        debugger?.breakpointsChanged(script: id)
    }

    /// A Luau script's breakpoint on or off — in the running game too.
    func toggleBreakpoint(script id: UUID, line: Int) {
        guard let script = model.script(id: id), script.language == .luau, line >= 1 else { return }
        let on = !script.breakpoints.contains(line)
        model.setBreakpoints(on ? script.breakpoints + [line] : script.breakpoints.filter { $0 != line }, forScript: id)
        play?.scripts.debugger?.setBreakpoint(script: id, line: line, on: on)
    }

    /// Continue, a step, or Stop, while stopped.
    func debug(_ command: ScriptDebugger.Command) {
        guard debugPause != nil else { return }
        debugCommand = command
    }

    /// Shows a call in the stack: its variables, and its line in its script.
    func showFrame(_ index: Int) {
        guard let pause = debugPause, pause.frames.indices.contains(index) else { return }
        let changed = debugFrame != index
        debugFrame = index
        if changed {
            debugOpened = [:]
            rewatch()
        }
        let frame = pause.frames[index]
        if let id = frame.scriptID { reveal(.script(id), line: frame.line) }
    }

    /// Shows a stop: the Debugger tab, and the line in its script (and any tables open,
    /// for a picture of the panel).
    func show(_ pause: ScriptDebugger.Pause, opened: [String: [LuauInterpreter.DebugVariable]] = [:],
              hits: [UUID: [Int: Int]]? = nil) {
        debugPause = pause
        if let hits = hits ?? debugger?.hits { breakpointHits = hits }
        debugCommand = nil
        debugOpened = opened
        debugFrame = 0
        showDock(.debugger)
        showFrame(0)
        if let top = pause.frames.first {
            model.statusText = "Paused at \(top.script):\(top.line)" + (pause.reason == .step ? "" : " (breakpoint)")
        }
    }

    /// A stop: shows where, then waits — the app still answering, the game frozen — for
    /// Continue, a step or Stop. With no app running (the self-tests), it goes straight on.
    private func paused(_ pause: ScriptDebugger.Pause) -> ScriptDebugger.Command {
        guard let app = NSApp, app.isRunning else { return .resume }
        show(pause)
        app.activate(ignoringOtherApps: true)
        while debugCommand == nil {
            autoreleasepool {
                if let event = app.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.05),
                                             inMode: .default, dequeue: true) {
                    app.sendEvent(event)
                }
            }
        }
        let command = debugCommand ?? .resume
        debugCommand = nil
        debugPause = nil
        debugOpened = [:]
        model.statusText = command == .stop ? "Stopping" : "Playing"
        return command
    }

    /// Opens the bottom panel on a given tab. The Animation Editor poses a rig in the
    /// viewport, so it brings the world to the front too.
    func showDock(_ tab: DockTab) {
        dockTab = tab
        dockVisible = true
        if tab == .animation || tab == .terrain { showWorld() }
        // Away from the Terrain Editor, clicks in the world select again.
        if tab != .terrain, viewport.model.terrainBrush != nil { viewport.model.terrainBrush = nil }
    }

    func togglePlay() {
        isPlaying ? stopPlay() : startPlay()
    }

    // MARK: - Tabs

    /// Split view (⌘\): the world and the tab in front side by side, instead of the tab
    /// covering the world.
    @Published var splitView = false
    /// The world's share of the width in split view.
    @Published var splitFraction: CGFloat = 0.5

    /// The world shows — alone, or beside a tab in split view — so the viewport draws.
    var showsWorld: Bool { activeDocument == nil || splitView }
    /// The World tab is the one in front: the viewport has the whole middle.
    var worldInFront: Bool { activeDocument == nil }

    func toggleSplitView() { splitView.toggle() }

    func showWorld() {
        if activeDocument != nil { activeDocument = nil }
    }

    /// Brings a document's tab to the front, opening one if it has none. Returns false
    /// for a script or shader that doesn't exist.
    @discardableResult
    func open(_ document: EditorDocument) -> Bool {
        guard exists(document) else { return false }
        if !documents.contains(document) { documents.append(document) }
        activeDocument = document
        return true
    }

    /// Opens a script's tab, scrolled to a line if one is given.
    @discardableResult
    func openScript(_ id: UUID, line: Int? = nil) -> Bool {
        if let line { return reveal(.script(id), line: line) }
        return open(.script(id))
    }

    /// Opens a tab and selects one of its lines — where an error in the Output happened.
    @discardableResult
    func reveal(_ document: EditorDocument, line: Int) -> Bool {
        guard open(document) else { return false }
        revealRequest = CodeReveal(document: document, line: line)
        return true
    }

    /// The latest line request, if it is for this document.
    func revealRequest(for document: EditorDocument) -> CodeReveal? {
        revealRequest?.document == document ? revealRequest : nil
    }

    @discardableResult
    func openShader(_ id: UUID) -> Bool { open(.shader(id)) }

    @discardableResult
    func openCoreScript(named name: String) -> Bool { open(.coreScript(name)) }

    /// Closes a tab. Closing the one in front brings forward the tab to its left, and
    /// the world after the last of them.
    func close(_ document: EditorDocument) {
        guard let index = documents.firstIndex(of: document) else { return }
        documents.remove(at: index)
        codeViews.forget(document.id)
        if activeDocument == document {
            activeDocument = index > 0 ? documents[index - 1] : nil
        }
    }

    /// Closes the tab in front; false when that is the world, which never closes.
    @discardableResult
    func closeActiveDocument() -> Bool {
        guard let active = activeDocument else { return false }
        close(active)
        return true
    }

    func closeOtherDocuments(than keep: EditorDocument) {
        closeDocuments { $0 != keep }
        if documents.contains(keep) { activeDocument = keep }
    }

    func closeAllDocuments() { closeDocuments { _ in true } }

    /// Moves along the tab strip — the world, then each document — wrapping at the ends.
    func selectAdjacentTab(_ step: Int) {
        let strip: [EditorDocument?] = [nil] + documents.map { Optional($0) }
        let current = strip.firstIndex(of: activeDocument) ?? 0
        let next = ((current + step) % strip.count + strip.count) % strip.count
        activeDocument = strip[next]
    }

    /// What a tab is called: the script or shader's name as it is now.
    func title(of document: EditorDocument) -> String {
        switch document {
        case .script(let id): return model.script(id: id)?.name ?? "Script"
        case .shader(let id): return model.shader(id: id)?.name ?? "Shader"
        case .coreScript(let name): return name
        }
    }

    private func exists(_ document: EditorDocument) -> Bool {
        switch document {
        case .script(let id): return model.script(id: id) != nil
        case .shader(let id): return model.shader(id: id) != nil
        case .coreScript(let name): return CoreScripts.all.contains { $0.name == name }
        }
    }

    private func closeDocuments(where shouldClose: (EditorDocument) -> Bool) {
        let doomed = documents.filter(shouldClose)
        guard !doomed.isEmpty else { return }
        // One at a time, so the tab in front hands over to its neighbour as usual.
        for document in doomed { close(document) }
    }
}
