import Foundation
import simd

// SceneModel — Shaders: surface shaders on parts, and the screen effect.

extension SceneModel {
    // MARK: - Shaders

    func shader(id: UUID) -> ShaderObject? { shaders.first { $0.id == id } }

    func updateShader(id: UUID, _ body: (inout ShaderObject) -> Void) {
        guard let i = shaders.firstIndex(where: { $0.id == id }) else { return }
        body(&shaders[i])
    }

    /// Shader text is edited live; like script text it marks the document dirty
    /// without pushing a scene-level undo step.
    func setShaderSource(id: UUID, source: String) {
        guard let i = shaders.firstIndex(where: { $0.id == id }), shaders[i].source != source else { return }
        shaders[i].source = source
        noteChange()
    }

    func uniqueShaderName(base: String) -> String { Self.unique(base, among: shaders.map(\.name)) }

    /// Shaders of one kind, in scene order.
    func shaders(kind: ShaderKind) -> [ShaderObject] { shaders.filter { $0.kind == kind } }

    /// The screen effects switched on, in the order they run: the order the shaders
    /// are listed in.
    var activeScreenShaders: [ShaderObject] {
        shaders.filter { $0.kind == .screen && screenShaderIDs.contains($0.id) }
    }

    var activeScreenShader: ShaderObject? { activeScreenShaders.first }

    /// Switches one screen effect on alone, or every one off.
    func setScreenShader(_ id: UUID?) {
        guard screenShaderIDs != (id.map { [$0] } ?? []) else { return }
        let name = id.flatMap { shader(id: $0) }?.name
        commit(name.map { "Screen shader: \($0)" } ?? "Screen shader off") {
            screenShaderIDs = id.map { [$0] } ?? []
        }
    }

    /// Moves a shader past the next one of its kind above (-1) or below (+1): for screen
    /// effects, the order they run in.
    func moveShader(_ id: UUID, by step: Int) {
        guard let index = shaders.firstIndex(where: { $0.id == id }) else { return }
        let kind = shaders[index].kind
        let others = shaders.indices.filter { shaders[$0].kind == kind }
        guard let place = others.firstIndex(of: index), others.indices.contains(place + step) else { return }
        commit("Moved \(shaders[index].name)") { shaders.swapAt(index, others[place + step]) }
    }

    /// Switches one screen effect on or off, leaving the others as they are.
    func toggleScreenShader(_ id: UUID) {
        guard let shader = shader(id: id), shader.kind == .screen else { return }
        let on = screenShaderIDs.contains(id)
        commit(on ? "\(shader.name) off" : "\(shader.name) on") {
            if on { screenShaderIDs.removeAll { $0 == id } } else { screenShaderIDs.append(id) }
        }
    }

    @discardableResult
    func addShader(kind: ShaderKind = .surface, name: String? = nil, source: String? = nil,
                   parameters: [ShaderParameter]? = nil) -> UUID {
        var shader = ShaderObject.blank(kind: kind)
        shader.name = uniqueShaderName(base: name ?? (kind == .surface ? "Shader" : "Screen Effect"))
        if let source { shader.source = source }
        if let parameters { shader.parameters = parameters }
        commit("Added \(shader.name)") {
            shaders.append(shader)
            selectedShader = shader.id
        }
        return shader.id
    }

    func deleteShader(id: UUID) {
        guard let shader = shader(id: id) else { return }
        commit("Deleted \(shader.name)") {
            shaders.removeAll { $0.id == id }
            for i in parts.indices where parts[i].shaderID == id {
                parts[i].shaderID = nil
            }
            screenShaderIDs.removeAll { $0 == id }
            if selectedShader == id { selectedShader = nil }
        }
    }

    func assignShader(_ shaderID: UUID?, to partIDs: Set<UUID>) {
        guard !partIDs.isEmpty else { return }
        let label = shaderID == nil ? "Cleared shader" : "Applied shader"
        commit(label) {
            for i in parts.indices where partIDs.contains(parts[i].id) {
                parts[i].shaderID = shaderID
            }
        }
    }
}
