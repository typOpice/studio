import Foundation
import simd

// SceneModel — Scripts: finding, adding and editing them, and their starter code.

extension SceneModel {
    // MARK: - Scripts

    func script(id: UUID) -> ScriptObject? { scripts.first { $0.id == id } }

    /// Scene scripts (and ModuleScripts) attached to a part, or in Script Service when
    /// `parentID` is nil.
    func scripts(parentID: UUID?) -> [ScriptObject] {
        scripts.filter { $0.host == .scene && $0.parentID == parentID }
    }

    /// The scene's own scripts in a StarterPlayer folder.
    func scripts(host: ScriptHost) -> [ScriptObject] { scripts.filter { $0.host == host } }

    /// The built-in scripts for a folder that nothing in the scene replaces.
    func defaultScripts(host: ScriptHost) -> [ScriptObject] {
        CoreScripts.active(overriddenBy: scripts).filter { $0.host == host }
    }

    /// Adds an editable copy of a built-in script. Having the same name, it replaces
    /// the default from then on.
    @discardableResult
    func copyCoreScript(named name: String) -> UUID? {
        guard let core = CoreScripts.all.first(where: { $0.name == name }) else { return nil }
        if let existing = scripts.first(where: { $0.host == core.host && $0.name == core.name }) {
            selectedScript = existing.id
            return existing.id
        }
        return addScript(language: .luau, host: core.host, name: core.name, source: core.source)
    }

    func updateScript(id: UUID, _ body: (inout ScriptObject) -> Void) {
        guard let i = scripts.firstIndex(where: { $0.id == id }) else { return }
        body(&scripts[i])
    }

    /// Script text is edited live; the text view owns its own undo, so this only
    /// marks the document dirty rather than pushing a scene-level undo step.
    func setScriptSource(id: UUID, source: String) {
        guard let i = scripts.firstIndex(where: { $0.id == id }), scripts[i].source != source else { return }
        scripts[i].source = source
        noteChange()
    }

    func uniqueScriptName(base: String) -> String { Self.unique(base, among: scripts.map(\.name)) }

    /// Where a script with this parent and host would live, which picks its starter code.
    func templatePlace(parentID: UUID?, host: ScriptHost) -> ScriptTemplates.Place {
        switch host {
        case .starterPlayer: return .starterPlayer
        case .starterCharacter: return .starterCharacter
        case .starterGui: return .gui
        case .replicatedStorage, .serverStorage: return .service
        case .scene:
            guard let parentID else { return .service }
            if part(id: parentID) != nil { return .part }
            if let group = group(id: parentID) { return group.kind == .model ? .model : .folder }
            return .service
        }
    }

    @discardableResult
    func addScript(parentID: UUID? = nil, language: ScriptLanguage = .luau,
                   host: ScriptHost = .scene, name: String? = nil, source: String? = nil) -> UUID {
        var script = ScriptObject.blank(language: language)
        script.host = host
        script.parentID = host == .scene || host == .starterGui ? parentID : nil
        script.source = source ?? ScriptTemplates.source(language, in: templatePlace(parentID: script.parentID, host: host))
        script.name = name ?? uniqueScriptName(base: language == .luau ? "Script" : "WrenScript")
        commit("Added \(script.name)") {
            scripts.append(script)
            selectedScript = script.id
        }
        return script.id
    }


    /// A new ModuleScript — in ReplicatedStorage, Script Service, or a part or Model —
    /// selected and open. With undo.
    @discardableResult
    func addModuleScript(parentID: UUID? = nil, host: ScriptHost = .replicatedStorage, name: String? = nil,
                         source: String? = nil) -> UUID {
        var script = ScriptObject.blank(language: .luau)
        script.kind = .module
        script.host = host == .replicatedStorage || host == .serverStorage ? host : .scene
        script.parentID = script.host == .scene ? parentID : nil
        script.source = source ?? ScriptObject.moduleTemplate
        script.name = name ?? uniqueScriptName(base: "ModuleScript")
        commit("Added \(script.name)") {
            scripts.append(script)
            selectedScript = script.id
        }
        return script.id
    }

    func deleteScript(id: UUID) {
        guard let script = script(id: id) else { return }
        commit("Deleted \(script.name)") {
            scripts.removeAll { $0.id == id }
            if selectedScript == id { selectedScript = nil }
        }
    }
}
