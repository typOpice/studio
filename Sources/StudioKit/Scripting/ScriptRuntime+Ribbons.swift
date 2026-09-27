import Foundation

// The script runtime's host calls for `ribbon.*`: a Beam's or Trail's looks (RibbonLook.swift).
// The rest of it — Attachment0, Attachment1, Enabled, Name — is a constraint's, through `constraint.*`.

extension ScriptRuntime {
    func ribbonCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        guard let id = uuid(arguments.first), let constraint = model.constraint(id: id), constraint.kind.isEffect,
              arguments.count > 1, let key = arguments[1].asString?.lowercased() else {
            return name == "ribbon.set" ? .bool(false) : .nothing
        }
        switch name {
        case "ribbon.get":
            return Self.ribbonProperty(constraint.look, key)
        case "ribbon.set":
            guard arguments.count > 2 else { return .bool(false) }
            if key == "clear" {
                model.updateConstraint(id: id) { $0.look.cleared += 1 }
                return .bool(true)
            }
            var look = constraint.look
            guard Self.setRibbonProperty(&look, key, arguments[2]) else { return .bool(false) }
            model.updateConstraint(id: id) { $0.look = look }
            return .bool(true)
        default:
            return unknownCall(name)
        }
    }

    static func ribbonProperty(_ look: RibbonLook, _ key: String) -> ScriptValue {
        func numbers(_ keys: [NumberKey]) -> ScriptValue {
            .list(keys.flatMap { [ScriptValue.number(Double($0.time)), .number(Double($0.value)), .number(Double($0.envelope))] })
        }
        switch key {
        case "color":
            return .list(look.color.flatMap { key in
                [ScriptValue.number(Double(key.time)), .number(Double(key.color.x)), .number(Double(key.color.y)),
                 .number(Double(key.color.z))]
            })
        case "transparency": return numbers(look.transparency)
        case "widthscale": return numbers(look.widthScale)
        case "lightemission": return .number(Double(look.lightEmission))
        case "brightness": return .number(Double(look.brightness))
        case "texture": return .string(look.texture)
        case "texturelength": return .number(Double(look.textureLength))
        case "texturemode": return .string(look.textureMode.rawValue)
        case "texturespeed": return .number(Double(look.textureSpeed))
        case "facecamera": return .bool(look.faceCamera)
        case "width0": return .number(Double(look.width0))
        case "width1": return .number(Double(look.width1))
        case "curvesize0": return .number(Double(look.curveSize0))
        case "curvesize1": return .number(Double(look.curveSize1))
        case "segments": return .number(Double(look.segments))
        case "lifetime": return .number(Double(look.lifetime))
        case "minlength": return .number(Double(look.minLength))
        case "maxlength": return .number(Double(look.maxLength))
        default: return .nothing
        }
    }

    /// Sets one of a Beam's or Trail's looks, the Luau side having checked its type; false
    /// when it's out of range (a sequence not from 0 to 1, a width below 0).
    static func setRibbonProperty(_ look: inout RibbonLook, _ key: String, _ value: ScriptValue) -> Bool {
        func floats() -> [Float]? {
            guard case .list(let items) = value else { return nil }
            let numbers = items.compactMap(\.asFloat)
            return numbers.count == items.count && numbers.allSatisfy(\.isFinite) ? numbers : nil
        }
        func number() -> Float? { value.asFloat.flatMap { $0.isFinite ? $0 : nil } }
        func ordered(_ times: [Float]) -> Bool {
            (2...20).contains(times.count) && times.first == 0 && times.last == 1 && zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }
        }
        func sequence() -> [NumberKey]? {
            guard let v = floats(), v.count % 3 == 0 else { return nil }
            let keys = stride(from: 0, to: v.count, by: 3).map { NumberKey(time: v[$0], value: v[$0 + 1], envelope: v[$0 + 2]) }
            return ordered(keys.map(\.time)) ? keys : nil
        }
        switch key {
        case "color":
            guard let v = floats(), v.count % 4 == 0 else { return false }
            let keys = stride(from: 0, to: v.count, by: 4).map { ColorKey(time: v[$0], color: Vec3(v[$0 + 1], v[$0 + 2], v[$0 + 3])) }
            guard ordered(keys.map(\.time)) else { return false }
            look.color = keys
        case "transparency": guard let keys = sequence() else { return false }; look.transparency = keys
        case "widthscale": guard let keys = sequence() else { return false }; look.widthScale = keys
        case "lightemission": guard let v = number() else { return false }; look.lightEmission = min(max(v, 0), 1)
        case "brightness": guard let v = number(), v >= 0 else { return false }; look.brightness = v
        case "texture": guard let v = value.asString else { return false }; look.texture = v
        case "texturelength": guard let v = number(), v > 0 else { return false }; look.textureLength = v
        case "texturemode":
            guard let v = value.asString.flatMap(RibbonLook.TextureMode.init(rawValue:)) else { return false }
            look.textureMode = v
        case "texturespeed": guard let v = number() else { return false }; look.textureSpeed = v
        case "facecamera": guard let v = value.asBool else { return false }; look.faceCamera = v
        case "width0": guard let v = number(), v >= 0 else { return false }; look.width0 = v
        case "width1": guard let v = number(), v >= 0 else { return false }; look.width1 = v
        case "curvesize0": guard let v = number() else { return false }; look.curveSize0 = v
        case "curvesize1": guard let v = number() else { return false }; look.curveSize1 = v
        case "segments": guard let v = number(), v >= 1 else { return false }; look.segments = min(Int(v.rounded()), 100)
        case "lifetime": guard let v = number(), v > 0 else { return false }; look.lifetime = min(v, 20)
        case "minlength": guard let v = number(), v >= 0 else { return false }; look.minLength = v
        case "maxlength": guard let v = number(), v >= 0 else { return false }; look.maxLength = v
        default: return false
        }
        return true
    }
}
