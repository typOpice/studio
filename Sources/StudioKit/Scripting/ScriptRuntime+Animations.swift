import Foundation
import simd

// The script runtime's host calls for `animation.*`: the animations made in the Animation Editor.
// `ScriptRuntime.invoke` routes each call here by the part of its name before the dot.

extension ScriptRuntime {
    /// Host calls for `animation.*`: the animations made in the Animation Editor.
    func animationsCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        // MARK: animations (made in the Animation Editor), by id or name
        case "animation.find":
            guard let name = arguments.first?.asString,
                  let animation = model.animation(named: name) else { return .nothing }
            return .string(animation.id.uuidString)

        case "animation.ids":
            return .list(model.animations.map { .string($0.id.uuidString) })

        case "animation.get":
            guard arguments.count >= 2, let key = arguments[0].asString,
                  let animation = model.animations.first(where: { $0.id.uuidString == key || $0.name == key })
            else { return .nothing }
            switch (arguments[1].asString ?? "").lowercased() {
            case "name": return .string(animation.name)
            case "length": return .number(Double(animation.length))
            case "looped": return .bool(animation.looped)
            case "priority": return .string(animation.priority.rawValue)
            default: return .nothing
            }

        default:
            return unknownCall(name)
        }
    }
}
