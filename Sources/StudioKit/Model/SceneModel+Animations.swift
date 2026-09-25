import Foundation
import simd

// SceneModel — Animations made in the Animation Editor.

extension SceneModel {
    // MARK: - Animations

    func animation(id: UUID) -> AnimationObject? { animations.first { $0.id == id } }

    func animation(named name: String) -> AnimationObject? { animations.first { $0.name == name } }

    func uniqueAnimationName(base: String) -> String { Self.unique(base, among: animations.map(\.name)) }

    @discardableResult
    func addAnimation(_ template: AnimationObject = AnimationObject()) -> UUID {
        var animation = template
        animation.id = UUID()
        animation.name = uniqueAnimationName(base: template.name)
        commit("Added \(animation.name)") {
            animations.append(animation)
            selectedAnimation = animation.id
        }
        return animation.id
    }

    func deleteAnimation(id: UUID) {
        guard let animation = animation(id: id) else { return }
        commit("Deleted \(animation.name)") {
            animations.removeAll { $0.id == id }
            if selectedAnimation == id { selectedAnimation = nil }
        }
    }

    /// Changes an animation without recording undo; wrap in `commit` or a stroke.
    func updateAnimation(id: UUID, _ body: (inout AnimationObject) -> Void) {
        guard let i = animations.firstIndex(where: { $0.id == id }) else { return }
        body(&animations[i])
    }

    /// An undoable edit to an animation.
    func editAnimation(_ id: UUID, _ label: String, _ body: (inout AnimationObject) -> Void) {
        commit(label) { updateAnimation(id: id, body) }
    }
}
