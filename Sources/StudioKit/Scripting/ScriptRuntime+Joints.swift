import Foundation
import simd

// The script runtime's host calls for `attachment.*` and `constraint.*`: attachments, welds and joints.
// `ScriptRuntime.invoke` routes each call here by the part of its name before the dot.

extension ScriptRuntime {
    /// Host calls for `attachment.*` and `constraint.*`: attachments, welds and joints.
    func jointsCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        // MARK: attachments
        case "attachment.create":
            guard let partID = uuid(arguments.first), model.part(id: partID) != nil else { return .nothing }
            let attachment = SceneAttachment(parentID: partID)
            model.attachments.append(attachment)
            return .string(attachment.id.uuidString)

        case "attachment.get":
            guard arguments.count >= 2, let id = uuid(arguments[0]), let a = model.attachment(id: id) else { return .nothing }
            func v(_ x: Vec3) -> ScriptValue { .triple(x.x, x.y, x.z) }
            switch (arguments[1].asString ?? "").lowercased() {
            case "name": return .string(a.name)
            case "position": return v(a.position)
            case "axis": return v(a.axis)
            case "secondaryaxis": return v(a.secondaryAxis)
            case "worldposition": return model.worldFrame(of: a).map { v($0.position) } ?? .nothing
            case "worldaxis": return model.worldFrame(of: a).map { v($0.axis) } ?? .nothing
            case "worldsecondaryaxis": return model.worldFrame(of: a).map { v($0.secondary) } ?? .nothing
            default: return .nothing
            }

        case "attachment.set":
            guard arguments.count >= 3, let id = uuid(arguments[0]) else { return .nothing }
            let value = arguments[2]
            model.updateAttachment(id: id) { a in
                switch (arguments[1].asString ?? "").lowercased() {
                case "name": if let name = value.asString { a.name = name }
                case "position": if let (x, y, z) = value.asTriple { a.position = Vec3(x, y, z) }
                case "axis": if let (x, y, z) = value.asTriple { a.setAxis(Vec3(x, y, z)) }
                case "secondaryaxis":
                    if let (x, y, z) = value.asTriple {
                        let s = Vec3(x, y, z) - a.axis * dot(Vec3(x, y, z), a.axis)
                        if simd_length(s) > 1e-5 { a.secondaryAxis = normalize(s) }
                    }
                default: break
                }
            }
            return .nothing

        case "attachment.destroy":
            guard let id = uuid(arguments.first) else { return .nothing }
            model.attachments.removeAll { $0.id == id }
            model.pruneConstraints()
            return .nothing

        // MARK: welds and joints
        case "constraint.create":
            guard let raw = arguments.first?.asString, let kind = SceneConstraint.Kind(rawValue: raw) else { return .nothing }
            let constraint = SceneConstraint(kind: kind)
            model.constraints.append(constraint)
            return .string(constraint.id.uuidString)

        case "constraint.get":
            guard arguments.count >= 2, let id = uuid(arguments[0]), let c = model.constraint(id: id) else { return .nothing }
            let key = (arguments[1].asString ?? "").lowercased()
            if let path = Self.constraintNumbers[key] { return .number(Double(c[keyPath: path])) }
            switch key {
            case "name": return .string(c.name)
            case "kind": return .string(c.kind.rawValue)
            case "enabled": return .bool(c.enabled)
            case "limitsenabled": return .bool(c.limitsEnabled)
            case "actuatortype": return .string(c.actuator.rawValue)
            case "part0": return c.part0.flatMap { model.part(id: $0) }.map { .string($0.id.uuidString) } ?? .nothing
            case "part1": return c.part1.flatMap { model.part(id: $0) }.map { .string($0.id.uuidString) } ?? .nothing
            case "attachment0": return c.attachment0.flatMap { model.attachment(id: $0) }.map { .string($0.id.uuidString) } ?? .nothing
            case "attachment1": return c.attachment1.flatMap { model.attachment(id: $0) }.map { .string($0.id.uuidString) } ?? .nothing
            case "active":
                let (a, b) = c.parts(in: model)
                return .bool(c.enabled && a != nil && b != nil && a != b)
            case "distance":
                guard let a0 = c.attachment0.flatMap({ model.attachment(id: $0) }).flatMap({ model.worldFrame(of: $0) }),
                      let a1 = c.attachment1.flatMap({ model.attachment(id: $0) }).flatMap({ model.worldFrame(of: $0) })
                else { return .number(0) }
                return .number(Double(simd_distance(a0.position, a1.position)))
            default: return .nothing
            }

        case "constraint.set":
            guard arguments.count >= 3, let id = uuid(arguments[0]) else { return .nothing }
            let key = (arguments[1].asString ?? "").lowercased()
            let value = arguments[2]
            model.updateConstraint(id: id) { c in
                if let path = Self.constraintNumbers[key], let number = value.asFloat {
                    c[keyPath: path] = number
                    return
                }
                switch key {
                case "name": if let name = value.asString { c.name = name }
                case "enabled": if let b = value.asBool { c.enabled = b }
                case "limitsenabled": if let b = value.asBool { c.limitsEnabled = b }
                case "actuatortype": if let raw = value.asString, let a = ActuatorType(rawValue: raw) { c.actuator = a }
                case "part0": c.part0 = uuid(value)
                case "part1": c.part1 = uuid(value)
                case "attachment0": c.attachment0 = uuid(value)
                case "attachment1": c.attachment1 = uuid(value)
                default: break
                }
            }
            return .nothing

        case "constraint.destroy":
            guard let id = uuid(arguments.first) else { return .nothing }
            model.constraints.removeAll { $0.id == id }
            return .nothing


        default:
            return unknownCall(name)
        }
    }

    /// A constraint's numeric properties, by their Roblox names in lower case.
    static let constraintNumbers: [String: WritableKeyPath<SceneConstraint, Float>] = [
        "lowerangle": \.lowerAngle, "upperangle": \.upperAngle, "angularvelocity": \.angularVelocity,
        "motormaxtorque": \.motorMaxTorque, "targetangle": \.targetAngle, "angularspeed": \.angularSpeed,
        "servomaxtorque": \.servoMaxTorque, "lowerlimit": \.lowerLimit, "upperlimit": \.upperLimit,
        "velocity": \.velocity, "motormaxforce": \.motorMaxForce, "targetposition": \.targetPosition,
        "speed": \.speed, "servomaxforce": \.servoMaxForce, "length": \.length, "freelength": \.freeLength,
        "stiffness": \.stiffness, "damping": \.damping,
    ]
}
