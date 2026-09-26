import Foundation
import Combine
import simd

enum GizmoMode: String, CaseIterable, Identifiable {
    case select, move, scale, rotate

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .move: return "move.3d"
        case .scale: return "scale.3d"
        case .rotate: return "rotate.3d"
        }
    }
}

final class SceneModel: ObservableObject {
    @Published var parts: [Part] = []
    /// Models and Folders. The tree lives in `parentID`s; see `SceneTree.swift`.
    @Published var groups: [SceneGroup] = []
    /// Points on parts, and the welds and joints between them.
    @Published var attachments: [SceneAttachment] = []
    @Published var constraints: [SceneConstraint] = []
    /// A weld or joint open in the Properties panel.
    @Published var selectedConstraint: UUID? {
        didSet { if selectedConstraint != nil { leaveStarterPlayer() } }
    }
    @Published var selectedAttachment: UUID? {
        didSet { if selectedAttachment != nil { leaveStarterPlayer() } }
    }
    @Published var scripts: [ScriptObject] = []
    @Published var shaders: [ShaderObject] = []
    /// The screen shader in front of the camera, or nil for an untouched picture.
    /// The screen effects switched on, run in shader order (see `activeScreenShaders`).
    @Published var screenShaderIDs: [UUID] = []
    /// GUIs made in Studio (StarterGui), and the one selected in the Explorer.
    @Published var starterGui: [StarterGuiObject] = []
    @Published var selectedGui: UUID? {
        didSet { if selectedGui != nil { leaveOthers(for: \.selectedGui) } }
    }
    /// Pictures and sounds brought into the scene, and its Sounds; the ones selected.
    @Published var assets: [SceneAsset] = [] {
        didSet { MeshLibrary.shared.register(assets) }
    }
    @Published var sounds: [SceneSound] = []
    /// Folders, Value objects and remotes (see DataObjects.swift), and the one selected.
    @Published var dataObjects: [DataObject] = []
    @Published var selectedDataObject: UUID? {
        didSet { if selectedDataObject != nil { leaveOthers(for: \.selectedDataObject) } }
    }
    /// Which default HUD the scene has been given; see `DefaultHud`.
    var defaultGui = 0
    @Published var selectedAsset: UUID? {
        didSet { if selectedAsset != nil { leaveOthers(for: \.selectedAsset) } }
    }
    @Published var selectedSound: UUID? {
        didSet { if selectedSound != nil { leaveOthers(for: \.selectedSound) } }
    }
    /// The first effect switched on; setting it switches that one on alone.
    var screenShaderID: UUID? {
        get { activeScreenShaders.first?.id }
        set { screenShaderIDs = newValue.map { [$0] } ?? [] }
    }
    /// The template characters are built from.
    @Published var starterPlayer = StarterPlayerSettings()
    /// How the scene is lit.
    @Published var lighting = LightingSettings()
    /// Lighting is selected in the Explorer, so the inspector shows it.
    @Published var lightingSelected = false
    /// Custom animations, edited in the Animation Editor.
    @Published var animations: [AnimationObject] = []
    /// The animation open in the Animation Editor.
    @Published var selectedAnimation: UUID?
    /// StarterPlayer is selected in the Explorer, so the inspector shows it.
    @Published var starterPlayerSelected = false
    /// A built-in script being viewed read-only, by name.
    @Published var selectedCoreScript: String?
    // Picking anything else in the Explorer leaves StarterPlayer and its defaults, and
    // whatever else was picked: one thing at a time, so nothing stale comes back.
    @Published var selection: Set<UUID> = [] {
        didSet {
            if !selection.isEmpty {
                leaveStarterPlayer()
                selectedConstraint = nil
                selectedAttachment = nil
                leaveOthers(for: \.selection)
            }
        }
    }
    @Published var selectedScript: UUID? {
        didSet { if selectedScript != nil { leaveStarterPlayer(); leaveOthers(for: \.selectedScript) } }
    }
    @Published var selectedShader: UUID? {
        didSet { if selectedShader != nil { leaveStarterPlayer(); leaveOthers(for: \.selectedShader) } }
    }

    private func leaveStarterPlayer() {
        if starterPlayerSelected { starterPlayerSelected = false }
        if lightingSelected { lightingSelected = false }
        if selectedCoreScript != nil { selectedCoreScript = nil }
    }

    /// Something was just picked: the GUI object, Sound, picture or sound file, script or
    /// shader picked before it lets go. (Parts stay picked beside a script, as when one is
    /// added to them.)
    private func leaveOthers(for picked: PartialKeyPath<SceneModel>) {
        if picked != \SceneModel.selectedGui, selectedGui != nil { selectedGui = nil }
        if picked != \SceneModel.selectedSound, selectedSound != nil { selectedSound = nil }
        if picked != \SceneModel.selectedAsset, selectedAsset != nil { selectedAsset = nil }
        if picked != \SceneModel.selectedDataObject, selectedDataObject != nil { selectedDataObject = nil }
        if picked == \SceneModel.selectedGui || picked == \SceneModel.selectedSound || picked == \SceneModel.selectedAsset
            || picked == \SceneModel.selectedDataObject {
            if !selection.isEmpty { selection = [] }
            if selectedConstraint != nil { selectedConstraint = nil }
            if selectedAttachment != nil { selectedAttachment = nil }
            leaveStarterPlayer()
        }
        if picked != \SceneModel.selectedScript, picked != \SceneModel.selectedShader {
            if selectedScript != nil { selectedScript = nil }
            if selectedShader != nil { selectedShader = nil }
        }
    }

    /// Nothing selected at all: parts, GUI objects, Sounds, files, scripts, shaders, joints,
    /// Lighting and StarterPlayer — and no join tool armed. The animation open in the
    /// Animation Editor stays open when asked to.
    func deselectAll(keepingAnimation: Bool = true) {
        cancelJoinTool()
        if !selection.isEmpty { selection = [] }
        selectedGui = nil
        selectedSound = nil
        selectedAsset = nil
        selectedDataObject = nil
        selectedScript = nil
        selectedShader = nil
        selectedConstraint = nil
        selectedAttachment = nil
        leaveStarterPlayer()
        if !keepingAnimation { selectedAnimation = nil }
    }

    /// Whether anything at all is selected.
    var hasAnySelection: Bool {
        !selection.isEmpty || selectedGui != nil || selectedSound != nil || selectedAsset != nil || selectedDataObject != nil
            || selectedScript != nil || selectedShader != nil || selectedConstraint != nil || selectedAttachment != nil
            || lightingSelected || starterPlayerSelected || selectedCoreScript != nil || joinTool != nil
    }

    /// Shows StarterPlayer's settings in the inspector.
    func selectStarterPlayer() {
        selection = []
        selectedScript = nil
        selectedShader = nil
        selectedCoreScript = nil
        lightingSelected = false
        starterPlayerSelected = true
    }

    /// Shows the Lighting settings in the inspector.
    func selectLighting() {
        selection = []
        selectedScript = nil
        selectedShader = nil
        selectedCoreScript = nil
        starterPlayerSelected = false
        lightingSelected = true
    }

    /// Opens one of the built-in scripts, read-only.
    func selectCoreScript(named name: String) {
        selection = []
        selectedScript = nil
        selectedShader = nil
        starterPlayerSelected = false
        lightingSelected = false
        selectedCoreScript = name
    }
    @Published var gizmoMode: GizmoMode = .move
    /// The weld or joint tool armed in the ribbon. While one is armed the next two
    /// parts clicked in the viewport are joined, and it stays armed for the pair after
    /// that; nil leaves the ordinary select and transform tools in charge.
    @Published var joinTool: SceneConstraint.Kind? {
        didSet { if joinTool == nil { joinPending = nil } }
    }
    /// The first part clicked with a join tool armed, waiting for its partner.
    @Published var joinPending: UUID?
    /// Picking a join tool while two or more parts are selected joins that whole
    /// selection at once, so a brick wall welds in one go. Off, the tool always asks
    /// for its two clicks. Remembered between launches.
    @Published var joinSelectionOnPick: Bool = SceneModel.storedJoinSelectionOnPick {
        didSet { UserDefaults.standard.set(joinSelectionOnPick, forKey: SceneModel.joinSelectionKey) }
    }
    static let joinSelectionKey = "StudioJoinSelectionOnPick"
    private static var storedJoinSelectionOnPick: Bool {
        UserDefaults.standard.object(forKey: joinSelectionKey) as? Bool ?? true
    }
    @Published var snapEnabled: Bool = true
    @Published var moveSnap: Float = 1
    @Published var rotateSnap: Float = 15
    @Published var scaleSnap: Float = 1
    @Published var showGrid: Bool = true
    @Published var localSpace: Bool = false
    @Published var statusText: String = "Ready"

    private var undoStack: [SceneState] = []
    private var redoStack: [SceneState] = []
    private var strokeBaseline: SceneState?
    private let undoLimit = 120

    /// Bumped whenever parts or scripts change, so a play session can notice.
    @Published private(set) var revision = 0

    /// Everything that undo, redo and saving operate on.
    var state: SceneState {
        get { SceneState(parts: parts, scripts: scripts, shaders: shaders,
                         screenShaderIDs: screenShaderIDs, starterPlayer: starterPlayer,
                         animations: animations, lighting: lighting, groups: groups,
                         attachments: attachments, constraints: constraints, starterGui: starterGui,
                         assets: assets, sounds: sounds, dataObjects: dataObjects, defaultGui: defaultGui) }
        set {
            parts = newValue.parts
            groups = newValue.groups
            attachments = newValue.attachments
            constraints = newValue.constraints
            starterGui = newValue.starterGui
            assets = newValue.assets
            sounds = newValue.sounds
            dataObjects = newValue.dataObjects
            if let id = selectedDataObject, !dataObjects.contains(where: { $0.id == id }) { selectedDataObject = nil }
            defaultGui = newValue.defaultGui
            scripts = newValue.scripts
            shaders = newValue.shaders
            screenShaderIDs = newValue.screenShaderIDs
            starterPlayer = newValue.starterPlayer
            animations = newValue.animations
            lighting = newValue.lighting
            if let id = selectedAnimation, !animations.contains(where: { $0.id == id }) {
                selectedAnimation = nil
            }
            revision += 1
        }
    }

    init() {
        loadStarterScene()
    }

    // MARK: - Queries

    /// The parts the selection moves: those selected, and every part inside a
    /// selected Model. (A selected Folder organises; it moves nothing.)
    var selectedParts: [Part] {
        let ids = effectiveSelection
        return parts.filter { ids.contains($0.id) }
    }

    var effectiveSelection: Set<UUID> {
        var ids = selection.filter { id in parts.contains { $0.id == id } }
        for id in selection where groups.contains(where: { $0.id == id && $0.kind == .model }) {
            ids.formUnion(partIDs(inSubtree: id))
        }
        return ids
    }

    func part(id: UUID) -> Part? { parts.first { $0.id == id } }

    func index(of id: UUID) -> Int? { parts.firstIndex { $0.id == id } }

    var selectionCenter: Vec3? {
        let selected = selectedParts
        guard !selected.isEmpty else { return nil }
        return selected.reduce(Vec3.zero) { $0 + $1.position } / Float(selected.count)
    }

    // MARK: - Undo grouping

    /// Begin a coalesced edit (one drag, one slider gesture) that undoes as a single step.
    func beginStroke() {
        if strokeBaseline == nil { strokeBaseline = state }
    }

    func endStroke() {
        guard let baseline = strokeBaseline else { return }
        strokeBaseline = nil
        if baseline != state {
            pushUndo(baseline)
            revision += 1
        }
    }

    /// Record a single atomic change.
    func commit(_ label: String = "", _ body: () -> Void) {
        let before = state
        body()
        if before != state {
            pushUndo(before)
            revision += 1
            if !label.isEmpty { statusText = label }
        }
    }

    /// Marks the scene changed without an undo step — for script and shader text, whose
    /// undo lives in the editor.
    func noteChange() { revision += 1 }

    /// Forgets undo and redo: a scene replaced wholesale starts a fresh history.
    func clearHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
    }

    private func pushUndo(_ snapshot: SceneState) {
        undoStack.append(snapshot)
        if undoStack.count > undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    /// How many steps there are to undo.
    var undoCount: Int { undoStack.count }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = keepingText(previous)
        pruneSelection()
        statusText = "Undo"
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = keepingText(next)
        pruneSelection()
        statusText = "Redo"
    }

    /// Script and shader text has its own undo, in its editor, so stepping the scene
    /// back or forward leaves the text of every script and shader as it is now —
    /// otherwise undoing a part move would silently throw away code typed since.
    private func keepingText(_ target: SceneState) -> SceneState {
        var target = target
        let scriptText = Dictionary(scripts.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        for index in target.scripts.indices {
            if let text = scriptText[target.scripts[index].id] { target.scripts[index].source = text }
        }
        let shaderText = Dictionary(shaders.map { ($0.id, $0.source) }, uniquingKeysWith: { first, _ in first })
        for index in target.shaders.indices {
            if let text = shaderText[target.shaders[index].id] { target.shaders[index].source = text }
        }
        return target
    }

    private func pruneSelection() {
        selection = selection.intersection(Set(parts.map(\.id)).union(groups.map(\.id)))
        if let script = selectedScript, !scripts.contains(where: { $0.id == script }) {
            selectedScript = nil
        }
        if let shader = selectedShader, !shaders.contains(where: { $0.id == shader }) {
            selectedShader = nil
        }
        if screenShaderIDs.contains(where: { id in !shaders.contains { $0.id == id } }) {
            screenShaderIDs.removeAll { id in !shaders.contains { $0.id == id } }
        }
    }

    // MARK: - Mutation

    func update(id: UUID, _ body: (inout Part) -> Void) {
        guard let i = index(of: id) else { return }
        body(&parts[i])
    }

    func updateSelected(_ body: (inout Part) -> Void) {
        let ids = effectiveSelection
        for i in parts.indices where ids.contains(parts[i].id) {
            body(&parts[i])
        }
    }

    /// `base`, or `base1`, `base2`… — the first not already taken, as Roblox Studio names
    /// copies. Parts, scripts, shaders and animations each keep names unique among their own.
    static func unique(_ base: String, among taken: [String]) -> String {
        let existing = Set(taken)
        if !existing.contains(base) { return base }
        var n = 1
        while existing.contains("\(base)\(n)") { n += 1 }
        return "\(base)\(n)"
    }

    func uniqueName(base: String) -> String { Self.unique(base, among: parts.map(\.name)) }

    @discardableResult
    func addPart(shape: PartShape, at position: Vec3? = nil) -> UUID {
        var part = Part()
        part.shape = shape
        part.name = uniqueName(base: shape.displayName)
        part.position = position ?? Vec3(0, 2, 0)
        switch shape {
        case .block: part.size = Vec3(4, 1, 2)
        case .sphere: part.size = Vec3(2, 2, 2)
        case .cylinder: part.size = Vec3(2, 2, 2)
        case .wedge: part.size = Vec3(4, 2, 2)
        case .truss: part.size = Vec3(2, 10, 2)
        }
        part.color = Self.palette[parts.count % Self.palette.count]
        commit("Inserted \(part.name)") {
            parts.append(part)
            selection = [part.id]
        }
        return part.id
    }

    func deleteSelected() {
        // With no parts selected, what the Properties panel shows: a Sound, a picture or
        // sound file, or a GUI object.
        if selection.isEmpty {
            if let id = selectedSound, sound(id: id) != nil { deleteSound(id) }
            else if let id = selectedAsset, asset(id: id) != nil { deleteAsset(id) }
            else if let id = selectedGui, guiObject(id: id) != nil { deleteGuiObject(id) }
            return
        }
        let count = selection.count
        commit("Deleted \(count) item\(count == 1 ? "" : "s")") {
            // Deleting something deletes what is inside it, as in Roblox.
            let roots = selectionRoots.filter { part(id: $0)?.locked != true }
            removeSubtrees(roots)
            selection = []
        }
    }

    func duplicateSelected() {
        let roots = selectionRoots
        if roots.isEmpty, let id = selectedGui, selectedSound == nil, selectedAsset == nil {
            duplicateGui(id)
            return
        }
        guard !roots.isEmpty else { return }
        commit("Duplicated \(roots.count) item\(roots.count == 1 ? "" : "s")") {
            var newIDs: Set<UUID> = []
            for id in roots {
                // Lift the copy by its height so it doesn't sit inside the original.
                let lift = boundingBox(of: partIDs(inSubtree: id))?.size.y ?? 0
                guard let copy = cloneSubtree(id, parent: parentID(of: id), offset: Vec3(0, lift, 0)) else { continue }
                if let original = part(id: id) { update(id: copy) { $0.name = uniqueName(base: original.name) } }
                if let original = group(id: id) { updateGroup(id: copy) { $0.name = uniqueGroupName(base: original.name) } }
                newIDs.insert(copy)
            }
            selection = newIDs
        }
    }

    func groundSelected() {
        guard !selection.isEmpty else { return }
        commit("Dropped to baseplate") {
            updateSelected { part in
                part.position.y = part.size.y / 2
            }
        }
    }

    func selectAll() {
        selection = Set(parts.filter { !$0.locked }.map(\.id))
    }

    // MARK: - Scene files

    func clearScene() {
        // A new scene starts with the default HUD, as Studio's starter scene does.
        let hud = DefaultHud.make()
        commit("New scene") {
            parts = []
            groups = []
            attachments = []
            constraints = []
            starterGui = hud.objects
            assets = []
            sounds = []
            defaultGui = DefaultHud.version
            scripts = hud.scripts
            shaders = []
            screenShaderID = nil
            starterPlayer = StarterPlayerSettings()
            animations = []
            selectedAnimation = nil
            lighting = LightingSettings()
            selection = []
            selectedScript = nil
            selectedShader = nil
        }
    }

    func encodeScene(shared: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(shared ? sharedState : state)
    }

    /// The world as joined players get it: all but this machine's own Sounds.
    var sharedState: SceneState {
        var shared = state
        shared.sounds.removeAll(where: \.local)
        shared.dataObjects.removeAll(where: \.local)
        return shared
    }

    /// Opens a scene file. One saved before the default HUD gets it (`upgrading`); a
    /// scene sent by a host is taken exactly as it is.
    func loadScene(from data: Data, upgrading: Bool = true) throws {
        var restored = try JSONDecoder().decode(SceneState.self, from: data).repairingDuplicateIDs()
        if upgrading { restored = restored.upgradedToDefaultHud() }
        commit("Opened scene") {
            state = restored
            selection = []
            selectedScript = nil
            selectedShader = nil
        }
        clearHistory()
    }

    static let palette: [Vec3] = [
        Vec3(0.64, 0.64, 0.64),
        Vec3(0.91, 0.45, 0.36),
        Vec3(0.36, 0.67, 0.91),
        Vec3(0.55, 0.80, 0.43),
        Vec3(0.95, 0.80, 0.36),
        Vec3(0.74, 0.50, 0.87),
        Vec3(0.95, 0.60, 0.75),
        Vec3(0.40, 0.78, 0.74)
    ]
}
