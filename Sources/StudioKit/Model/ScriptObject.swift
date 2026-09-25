import Foundation

/// Which language a script is written in. Luau is the primary language and gets
/// every new feature first; Wren is supported alongside it and catches up on
/// alternate major releases.
enum ScriptLanguage: String, Codable, CaseIterable, Identifiable {
    case luau
    case wren

    var id: String { rawValue }
    var displayName: String { self == .luau ? "Luau" : "Wren" }
    var badge: String { self == .luau ? "lua" : "wren" }
}

/// Where a script lives, which decides when it runs — Roblox's containers.
enum ScriptHost: String, Codable, CaseIterable, Identifiable {
    /// In the Workspace (attached to a part) or Script Service. Runs once per session.
    case scene
    /// StarterPlayer › StarterPlayerScripts. Runs once per session, for the player.
    case starterPlayer
    /// StarterPlayer › StarterCharacterScripts. Runs again for every new character,
    /// with `script.Parent` set to that character; stopped when the character goes.
    case starterCharacter
    /// Inside a GUI object in StarterGui (a LocalScript): runs in each player's copy of
    /// that GUI, with the copy as `script.Parent`.
    case starterGui

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .scene: return "Scene"
        case .starterPlayer: return "StarterPlayerScripts"
        case .starterCharacter: return "StarterCharacterScripts"
        case .starterGui: return "StarterGui"
        }
    }
}

/// A script stored in the scene. Scripts attached to a part receive that part as
/// `script.Parent` (Luau) or `script.parent` (Wren); unattached scripts live under
/// Script Service, the way loose scripts live outside the Workspace in Roblox.
struct ScriptObject: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String = "Script"
    var language: ScriptLanguage = .luau
    var host: ScriptHost = .scene
    var source: String = ScriptObject.template
    var enabled: Bool = true
    var parentID: UUID?

    init() {}

    /// A fresh script in the given language, starting from its Script Service template.
    static func blank(language: ScriptLanguage) -> ScriptObject {
        var script = ScriptObject()
        script.language = language
        script.source = language == .luau ? template : wrenTemplate
        return script
    }

    private enum CodingKeys: String, CodingKey { case id, name, language, host, source, enabled, parentID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Script"
        // Every script saved before Luau arrived was Wren and carries no language
        // field, so an absent one means Wren — not the default for new scripts.
        language = try c.decodeIfPresent(ScriptLanguage.self, forKey: .language) ?? .wren
        host = try c.decodeIfPresent(ScriptHost.self, forKey: .host) ?? .scene
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
    }

    /// What a script in Script Service starts with; `ScriptTemplates` has one for every
    /// place a script can be made.
    static let template = ScriptTemplates.source(.luau, in: .service)
    static let wrenTemplate = ScriptTemplates.source(.wren, in: .service)
}

/// Everything an undo step or a saved file needs to restore.
struct SceneState: Equatable, Codable {
    var parts: [Part] = []
    var scripts: [ScriptObject] = []
    var shaders: [ShaderObject] = []
    /// The screen effects switched on. They run one after another in the order the
    /// shaders are listed (scene order), not the order they were switched on.
    var screenShaderIDs: [UUID] = []
    /// The first effect switched on — the only one, before effects could be chained.
    var screenShaderID: UUID? {
        get { shaders.first { $0.kind == .screen && screenShaderIDs.contains($0.id) }?.id ?? screenShaderIDs.first }
        set { screenShaderIDs = newValue.map { [$0] } ?? [] }
    }
    /// The template characters are built from.
    var starterPlayer = StarterPlayerSettings()
    /// Custom animations made in the Animation Editor.
    var animations: [AnimationObject] = []
    /// How the scene is lit.
    var lighting = LightingSettings()
    /// Models and Folders; parts name them as their parent.
    var groups: [SceneGroup] = []
    /// Points on parts that joints connect.
    var attachments: [SceneAttachment] = []
    /// Welds and joints.
    var constraints: [SceneConstraint] = []
    /// GUIs made in Studio, which every player gets a copy of.
    var starterGui: [StarterGuiObject] = []
    /// Pictures and sounds brought in, and the Sounds that play them.
    var assets: [SceneAsset] = []
    var sounds: [SceneSound] = []
    /// Which default HUD the scene has been given (`DefaultHud.version`); 0 is a scene
    /// from before there was one.
    var defaultGui = 0

    private enum CodingKeys: String, CodingKey {
        case parts, scripts, shaders, screenShaderID, screenShaderIDs, starterPlayer, animations, lighting, groups
        case attachments, constraints, starterGui, assets, sounds, defaultGui
    }

    init(parts: [Part] = [], scripts: [ScriptObject] = [], shaders: [ShaderObject] = [],
         screenShaderID: UUID? = nil, screenShaderIDs: [UUID] = [],
         starterPlayer: StarterPlayerSettings = StarterPlayerSettings(),
         animations: [AnimationObject] = [], lighting: LightingSettings = LightingSettings(),
         groups: [SceneGroup] = [], attachments: [SceneAttachment] = [],
         constraints: [SceneConstraint] = [], starterGui: [StarterGuiObject] = [],
         assets: [SceneAsset] = [], sounds: [SceneSound] = [], defaultGui: Int = 0) {
        self.defaultGui = defaultGui
        self.starterGui = starterGui
        self.assets = assets
        self.sounds = sounds
        self.lighting = lighting
        self.groups = groups
        self.attachments = attachments
        self.constraints = constraints
        self.parts = parts
        self.scripts = scripts
        self.shaders = shaders
        self.screenShaderIDs = screenShaderIDs.isEmpty ? screenShaderID.map { [$0] } ?? [] : screenShaderIDs
        self.starterPlayer = starterPlayer
        self.animations = animations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        parts = try c.decodeIfPresent([Part].self, forKey: .parts) ?? []
        scripts = try c.decodeIfPresent([ScriptObject].self, forKey: .scripts) ?? []
        shaders = try c.decodeIfPresent([ShaderObject].self, forKey: .shaders) ?? []
        // Files from before effects chained name one.
        screenShaderIDs = try c.decodeIfPresent([UUID].self, forKey: .screenShaderIDs)
            ?? (try c.decodeIfPresent(UUID.self, forKey: .screenShaderID)).map { [$0] } ?? []
        starterPlayer = try c.decodeIfPresent(StarterPlayerSettings.self, forKey: .starterPlayer)
            ?? StarterPlayerSettings()
        animations = try c.decodeIfPresent([AnimationObject].self, forKey: .animations) ?? []
        lighting = try c.decodeIfPresent(LightingSettings.self, forKey: .lighting) ?? LightingSettings()
        groups = try c.decodeIfPresent([SceneGroup].self, forKey: .groups) ?? []
        attachments = try c.decodeIfPresent([SceneAttachment].self, forKey: .attachments) ?? []
        constraints = try c.decodeIfPresent([SceneConstraint].self, forKey: .constraints) ?? []
        starterGui = try c.decodeIfPresent([StarterGuiObject].self, forKey: .starterGui) ?? []
        assets = try c.decodeIfPresent([SceneAsset].self, forKey: .assets) ?? []
        sounds = try c.decodeIfPresent([SceneSound].self, forKey: .sounds) ?? []
        defaultGui = try c.decodeIfPresent(Int.self, forKey: .defaultGui) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(parts, forKey: .parts)
        try c.encode(scripts, forKey: .scripts)
        try c.encode(shaders, forKey: .shaders)
        // The first as well, for older copies of Studio.
        try c.encodeIfPresent(screenShaderID, forKey: .screenShaderID)
        try c.encode(screenShaderIDs, forKey: .screenShaderIDs)
        try c.encode(starterPlayer, forKey: .starterPlayer)
        try c.encode(animations, forKey: .animations)
        try c.encode(lighting, forKey: .lighting)
        try c.encode(groups, forKey: .groups)
        try c.encode(attachments, forKey: .attachments)
        try c.encode(constraints, forKey: .constraints)
        if !starterGui.isEmpty { try c.encode(starterGui, forKey: .starterGui) }
        if !assets.isEmpty { try c.encode(assets, forKey: .assets) }
        if !sounds.isEmpty { try c.encode(sounds, forKey: .sounds) }
        if defaultGui > 0 { try c.encode(defaultGui, forKey: .defaultGui) }
    }
}

extension SceneState {
    /// The scene with every id unique. Two parts, scripts or joints sharing an id only
    /// come from a file edited by hand, but the physics, the tree and undo all look
    /// things up by id and would trip over it — the physics traps outright — so the
    /// later copies get fresh ids. Whatever pointed at the shared id keeps the first.
    func repairingDuplicateIDs() -> SceneState {
        var state = self
        var seen: Set<UUID> = []
        func unique(_ id: inout UUID) {
            if seen.insert(id).inserted { return }
            id = UUID()
            seen.insert(id)
        }
        for index in state.parts.indices { unique(&state.parts[index].id) }
        for index in state.groups.indices { unique(&state.groups[index].id) }
        for index in state.scripts.indices { unique(&state.scripts[index].id) }
        for index in state.shaders.indices { unique(&state.shaders[index].id) }
        for index in state.animations.indices { unique(&state.animations[index].id) }
        for index in state.attachments.indices { unique(&state.attachments[index].id) }
        for index in state.constraints.indices { unique(&state.constraints[index].id) }
        return state
    }
}
