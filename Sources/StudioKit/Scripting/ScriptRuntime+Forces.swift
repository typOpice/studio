import Foundation

// The script runtime's host calls for `force.*`: an AlignPosition's or VectorForce's own
// properties (Constraints.swift). Their attachments, Enabled and Name are a constraint's,
// through `constraint.*`.

extension ScriptRuntime {
    func forceCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        guard let id = uuid(arguments.first), let c = model.constraint(id: id), c.kind.isForce, arguments.count > 1,
              let key = arguments[1].asString?.lowercased() else {
            return name == "force.set" ? .bool(false) : .nothing
        }
        func vector(_ v: Vec3) -> ScriptValue { .list([.number(Double(v.x)), .number(Double(v.y)), .number(Double(v.z))]) }
        switch name {
        case "force.get":
            switch key {
            case "mode": return .string(c.alignMode.rawValue)
            case "position": return vector(c.position)
            case "maxforce": return .number(Double(c.maxForce))
            case "maxvelocity": return .number(Double(c.maxVelocity))
            case "responsiveness": return .number(Double(c.responsiveness))
            case "rigidityenabled": return .bool(c.rigidityEnabled)
            case "applyatcenterofmass": return .bool(c.applyAtCenterOfMass)
            case "force": return vector(c.force)
            case "relativeto": return .string(c.relativeTo.rawValue)
            default: return .nothing
            }
        case "force.set":
            guard arguments.count > 2 else { return .bool(false) }
            let value = arguments[2]
            func number() -> Float? { value.asFloat.flatMap { $0.isNaN ? nil : $0 } }
            func triple() -> Vec3? {
                guard case .list(let items) = value, items.count == 3 else { return nil }
                let v = items.compactMap(\.asFloat)
                return v.count == 3 && v.allSatisfy(\.isFinite) ? Vec3(v[0], v[1], v[2]) : nil
            }
            var changed = c
            switch key {
            case "mode": guard let v = value.asString.flatMap(AlignMode.init(rawValue:)) else { return .bool(false) }; changed.alignMode = v
            case "position": guard let v = triple() else { return .bool(false) }; changed.position = v
            case "maxforce": guard let v = number(), v >= 0 else { return .bool(false) }; changed.maxForce = v
            case "maxvelocity": guard let v = number(), v >= 0 else { return .bool(false) }; changed.maxVelocity = v
            case "responsiveness": guard let v = number(), v.isFinite else { return .bool(false) }; changed.responsiveness = min(max(v, 5), 200)
            case "rigidityenabled": guard let v = value.asBool else { return .bool(false) }; changed.rigidityEnabled = v
            case "applyatcenterofmass": guard let v = value.asBool else { return .bool(false) }; changed.applyAtCenterOfMass = v
            case "force": guard let v = triple() else { return .bool(false) }; changed.force = v
            case "relativeto":
                guard let v = value.asString.flatMap(ForceFrame.init(rawValue:)) else { return .bool(false) }
                changed.relativeTo = v
            default: return .bool(false)
            }
            model.updateConstraint(id: id) { $0 = changed }
            return .bool(true)
        default:
            return unknownCall(name)
        }
    }
}
