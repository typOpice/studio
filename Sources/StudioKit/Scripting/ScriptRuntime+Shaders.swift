import Foundation
import simd

// The script runtime's host calls for `shader.*` and `screen.*`: user shaders and the screen effect.
// `ScriptRuntime.invoke` routes each call here by the part of its name before the dot.

extension ScriptRuntime {
    /// Host calls for `shader.*` and `screen.*`: user shaders and the screen effect.
    func shadersCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        case "shader.count":
            return .number(Double(model.shaders.count))

        case "shader.ids":
            if let raw = arguments.first?.asString, let kind = ShaderKind(rawValue: raw) {
                return .list(model.shaders(kind: kind).map { .string($0.id.uuidString) })
            }
            return .list(model.shaders.map { .string($0.id.uuidString) })

        case "shader.find":
            guard let target = arguments.first?.asString,
                  let found = model.shaders.first(where: { $0.name == target }) else { return .nothing }
            return .string(found.id.uuidString)

        case "shader.get":
            guard arguments.count >= 2, let shader = shader(arguments[0]),
                  let property = arguments[1].asString else { return .nothing }
            switch property {
            case "name": return .string(shader.name)
            case "enabled": return .bool(shader.enabled)
            case "compiled": return .bool(shaderStatus?.status(for: shader.id) == .ready)
            case "kind": return .string(shader.kind.rawValue)
            default:
                console.error("Shader has no property \"\(property)\".")
                return .nothing
            }

        case "shader.set":
            guard arguments.count >= 3, let shader = shader(arguments[0]),
                  let property = arguments[1].asString else { return .nothing }
            if property == "enabled", let value = arguments[2].asBool {
                model.updateShader(id: shader.id) { $0.enabled = value }
            } else {
                console.error("Shader property \"\(property)\" cannot be set from a script.")
            }
            return .nothing

        case "shader.parameters":
            guard let shader = shader(arguments.first ?? .nothing) else { return .list([]) }
            return .list(shader.parameters.map { .string($0.name) })

        case "shader.param.get":
            guard arguments.count >= 2, let shader = shader(arguments[0]),
                  let name = arguments[1].asString else { return .nothing }
            guard let parameter = shader.parameter(named: name) else {
                console.error("Shader \"\(shader.name)\" has no parameter \"\(name)\".")
                return .nothing
            }
            return .number(Double(parameter.value))

        case "shader.param.set":
            guard arguments.count >= 3, let shader = shader(arguments[0]),
                  let name = arguments[1].asString, let value = arguments[2].asFloat else { return .nothing }
            guard shader.parameter(named: name) != nil else {
                console.error("Shader \"\(shader.name)\" has no parameter \"\(name)\".")
                return .nothing
            }
            model.updateShader(id: shader.id) { object in
                for index in object.parameters.indices where object.parameters[index].name == name {
                    object.parameters[index].value = value
                }
            }
            return .nothing

        case "screen.list":
            return .list(model.activeScreenShaders.map { .string($0.id.uuidString) })

        case "screen.add", "screen.remove":
            guard let shader = shader(arguments.first ?? .nothing), shader.kind == .screen else {
                console.error("Screen effects must be screen shaders.")
                return .nothing
            }
            if (name == "screen.add") != model.screenShaderIDs.contains(shader.id) {
                model.toggleScreenShader(shader.id)
            }
            return .nothing

        case "screen.get":
            guard let id = model.screenShaderID, model.shader(id: id) != nil else { return .nothing }
            return .string(id.uuidString)

        case "screen.set":
            guard let first = arguments.first, case .string(let raw) = first,
                  let id = UUID(uuidString: raw) else {
                model.setScreenShader(nil)
                return .nothing
            }
            guard let shader = model.shader(id: id) else { return .nothing }
            guard shader.kind == .screen else {
                console.error("\"\(shader.name)\" is a surface shader — Screen.shader needs a screen shader.")
                return .nothing
            }
            model.setScreenShader(id)
            return .nothing

        default:
            return unknownCall(name)
        }
    }

    func shader(_ value: ScriptValue) -> ShaderObject? {
        guard let string = value.asString, let id = UUID(uuidString: string) else { return nil }
        return model.shader(id: id)
    }
}
