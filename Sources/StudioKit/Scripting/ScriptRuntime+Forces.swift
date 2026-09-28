import Foundation

// The script runtime's host calls for `force.*`: the own properties of an AlignPosition,
// VectorForce, AlignOrientation, Torque or Motor6D (Constraints.swift). Their attachments
// or parts, Enabled and Name are a constraint's, through `constraint.*`.

extension ScriptRuntime {
    func forceCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        guard let id = uuid(arguments.first), let c = model.constraint(id: id), c.kind.isForce || c.kind == .motor6d,
              arguments.count > 1,
              let key = arguments[1].asString?.lowercased() else {
            return name == "force.set" ? .bool(false) : .nothing
        }
        func vector(_ v: Vec3) -> ScriptValue { .list([.number(Double(v.x)), .number(Double(v.y)), .number(Double(v.z))]) }
        func frame(_ pose: Pose) -> ScriptValue { .list(pose.components.map { .number(Double($0)) }) }
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
            case "cframe": return frame(c.cframe)
            case "maxtorque": return .number(Double(c.maxTorque))
            case "maxangularvelocity": return .number(Double(c.maxAngularVelocity))
            case "primaryaxisonly": return .bool(c.primaryAxisOnly)
            case "torque": return vector(c.torque)
            case "c0": return frame(c.c0)
            case "c1": return frame(c.c1)
            case "transform": return frame(c.transform)
            case "currentangle": return .number(Double(c.currentAngle))
            case "desiredangle": return .number(Double(c.desiredAngle))
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
            case "cframe": guard let v = poseValue(value) else { return .bool(false) }; changed.cframe = v
            case "maxtorque": guard let v = number(), v >= 0 else { return .bool(false) }; changed.maxTorque = v
            case "maxangularvelocity": guard let v = number(), v >= 0 else { return .bool(false) }; changed.maxAngularVelocity = v
            case "primaryaxisonly": guard let v = value.asBool else { return .bool(false) }; changed.primaryAxisOnly = v
            case "torque": guard let v = triple() else { return .bool(false) }; changed.torque = v
            case "c0": guard let v = poseValue(value) else { return .bool(false) }; changed.c0 = v
            case "c1": guard let v = poseValue(value) else { return .bool(false) }; changed.c1 = v
            case "transform": guard let v = poseValue(value) else { return .bool(false) }; changed.transform = v
            case "currentangle":
                guard let v = number(), v.isFinite else { return .bool(false) }
                changed.currentAngle = v
                changed.angleWrites += 1
            case "desiredangle": guard let v = number(), v.isFinite else { return .bool(false) }; changed.desiredAngle = v
            default: return .bool(false)
            }
            model.updateConstraint(id: id) { $0 = changed }
            return .bool(true)
        default:
            return unknownCall(name)
        }
    }
}
