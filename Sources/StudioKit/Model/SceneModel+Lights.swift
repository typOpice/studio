import Foundation

extension SceneModel {
    func lightParent(_ id: UUID) -> UUID? { parts.first { $0.lights.contains { $0.id == id } }?.id }
    func light(_ id: UUID) -> PointLight? {
        for part in parts { if let light = part.lights.first(where: { $0.id == id }) { return light } }
        return nil
    }
    func updateLight(_ id: UUID, _ body: (inout PointLight) -> Void) {
        guard let parent = lightParent(id) else { return }
        update(id: parent) { part in
            guard let index = part.lights.firstIndex(where: { $0.id == id }) else { return }
            body(&part.lights[index])
        }
    }
    @discardableResult
    func addLight(_ kind: PointLight.Kind, to parent: UUID) -> UUID? {
        guard part(id: parent) != nil else { return nil }
        let light = PointLight(kind: kind)
        commit("Added \(kind.rawValue)") { update(id: parent) { $0.lights.append(light) } }
        selectedLight = light.id
        return light.id
    }
    func removeLight(_ id: UUID) {
        guard let parent = lightParent(id) else { return }
        commit("Deleted Light") { update(id: parent) { $0.lights.removeAll { $0.id == id } } }
        if selectedLight == id { selectedLight = nil }
    }
}
