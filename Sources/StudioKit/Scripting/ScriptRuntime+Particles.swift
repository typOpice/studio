import Foundation

// The script runtime's host calls for `emitter.*`: ParticleEmitters (ParticleEmitter.swift).
// Scripts name one "<part>:<emitter>" when it's in a part, and "-:<emitter>" when it's in
// nothing (made, cloned, or taken out, and not yet put anywhere: `looseEmitters`).

extension ScriptRuntime {
    func emitterCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        case "emitter.create":
            let emitter = ParticleEmitter()
            if let part = uuid(arguments.first), model.part(id: part) != nil {
                model.update(id: part) { $0.emitters.append(emitter) }
                return .string(emitterName(part, emitter.id))
            }
            looseEmitters[emitter.id] = emitter
            return .string(emitterName(nil, emitter.id))

        case "emitter.get":
            guard let (part, emitter) = emitterParts(arguments.first), let found = findEmitter(part, emitter),
                  arguments.count > 1, let key = arguments[1].asString else { return .nothing }
            if key == "parent" { return part.map { .string("p:" + $0.uuidString) } ?? .nothing }
            return Self.emitterProperty(found, key)

        case "emitter.set":
            guard let (part, emitter) = emitterParts(arguments.first), arguments.count > 2,
                  let key = arguments[1].asString else { return .bool(false) }
            var accepted = false
            changeEmitter(part, emitter) { accepted = Self.setEmitterProperty(&$0, key, arguments[2]) }
            return .bool(accepted)

        case "emitter.emit":
            guard let (part, emitter) = emitterParts(arguments.first),
                  let count = arguments.count > 1 ? arguments[1].asDouble : nil, count.isFinite, count > 0 else {
                return .nothing
            }
            let burst = Int(min(count, Double(ParticleEmitter.most)))
            changeEmitter(part, emitter) {
                $0.emitted += burst
                $0.lastBurst = burst
            }
            return .nothing

        case "emitter.clear":
            guard let (part, emitter) = emitterParts(arguments.first) else { return .nothing }
            changeEmitter(part, emitter) { $0.cleared += 1 }
            return .nothing

        case "emitter.parent":
            // Into a part (by id), or out into nothing; the emitter's new name.
            guard let (from, id) = emitterParts(arguments.first), var emitter = takeEmitter(from, id) else { return .nothing }
            emitter.emitted = 0
            emitter.lastBurst = 0
            if let to = uuid(arguments.count > 1 ? arguments[1] : nil), model.part(id: to) != nil {
                model.update(id: to) { $0.emitters.append(emitter) }
                return .string(emitterName(to, id))
            }
            looseEmitters[id] = emitter
            return .string(emitterName(nil, id))

        case "emitter.clone":
            guard let (part, id) = emitterParts(arguments.first), var copy = findEmitter(part, id) else { return .nothing }
            copy.id = UUID()
            copy.emitted = 0
            copy.lastBurst = 0
            looseEmitters[copy.id] = copy
            return .string(emitterName(nil, copy.id))

        case "emitter.destroy":
            if let (part, id) = emitterParts(arguments.first) { _ = takeEmitter(part, id) }
            return .nothing

        default:
            return unknownCall(name)
        }
    }

    private func emitterName(_ part: UUID?, _ emitter: UUID) -> String {
        (part?.uuidString ?? "-") + ":" + emitter.uuidString
    }

    /// "<part>:<emitter>" or "-:<emitter>" apart.
    private func emitterParts(_ value: ScriptValue?) -> (UUID?, UUID)? {
        guard let text = value?.asString else { return nil }
        let pieces = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard pieces.count == 2, let emitter = UUID(uuidString: pieces[1]) else { return nil }
        if pieces[0] == "-" { return (nil, emitter) }
        guard let part = UUID(uuidString: pieces[0]) else { return nil }
        return (part, emitter)
    }

    private func findEmitter(_ part: UUID?, _ id: UUID) -> ParticleEmitter? {
        guard let part else { return looseEmitters[id] }
        return model.part(id: part)?.emitters.first { $0.id == id }
    }

    private func changeEmitter(_ part: UUID?, _ id: UUID, _ body: (inout ParticleEmitter) -> Void) {
        if let part {
            model.updateEmitter(EmitterRef(part: part, emitter: id), body)
        } else if var emitter = looseEmitters[id] {
            body(&emitter)
            looseEmitters[id] = emitter
        }
    }

    /// Out of where it is, for good or to go somewhere else.
    private func takeEmitter(_ part: UUID?, _ id: UUID) -> ParticleEmitter? {
        guard let part else { return looseEmitters.removeValue(forKey: id) }
        guard let emitter = findEmitter(part, id) else { return nil }
        model.update(id: part) { $0.emitters.removeAll { $0.id == id } }
        return emitter
    }

    // MARK: - Properties

    static func emitterProperty(_ e: ParticleEmitter, _ key: String) -> ScriptValue {
        func pair(_ v: SIMD2<Float>) -> ScriptValue { .list([.number(Double(v.x)), .number(Double(v.y))]) }
        switch key {
        case "name": return .string(e.name)
        case "enabled": return .bool(e.enabled)
        case "lockedtopart": return .bool(e.lockedToPart)
        case "rate": return .number(Double(e.rate))
        case "drag": return .number(Double(e.drag))
        case "lightemission": return .number(Double(e.lightEmission))
        case "brightness": return .number(Double(e.brightness))
        case "timescale": return .number(Double(e.timeScale))
        case "lifetime": return pair(e.lifetime)
        case "speed": return pair(e.speed)
        case "rotation": return pair(e.rotation)
        case "rotspeed": return pair(e.rotSpeed)
        case "spreadangle": return pair(e.spreadAngle)
        case "acceleration":
            return .list([.number(Double(e.acceleration.x)), .number(Double(e.acceleration.y)), .number(Double(e.acceleration.z))])
        case "size", "transparency":
            let keys = key == "size" ? e.size : e.transparency
            return .list(keys.flatMap { [ScriptValue.number(Double($0.time)), .number(Double($0.value)), .number(Double($0.envelope))] })
        case "color":
            return .list(e.color.flatMap { key in
                [ScriptValue.number(Double(key.time)), .number(Double(key.color.x)), .number(Double(key.color.y)),
                 .number(Double(key.color.z))]
            })
        case "emissiondirection": return .string(e.emissionDirection.rawValue)
        case "texture": return .string(e.texture)
        default: return .nothing
        }
    }

    /// Sets a property from a script, already the right type on the Luau side; false when
    /// the value isn't one it can have (a range the wrong way round, a sequence not from
    /// 0 to 1).
    static func setEmitterProperty(_ e: inout ParticleEmitter, _ key: String, _ value: ScriptValue) -> Bool {
        func floats() -> [Float]? {
            guard case .list(let items) = value else { return nil }
            let numbers = items.compactMap(\.asFloat)
            return numbers.count == items.count && numbers.allSatisfy(\.isFinite) ? numbers : nil
        }
        func range() -> SIMD2<Float>? {
            guard let v = floats(), v.count == 2, ParticleEmitter.validRange(SIMD2(v[0], v[1])) else { return nil }
            return SIMD2(v[0], v[1])
        }
        func number() -> Float? { value.asFloat.flatMap { $0.isFinite ? $0 : nil } }
        func ordered(_ times: [Float]) -> Bool {
            (2...20).contains(times.count) && times.first == 0 && times.last == 1 && zip(times, times.dropFirst()).allSatisfy { $0 <= $1 }
        }
        switch key {
        case "name": guard let v = value.asString else { return false }; e.name = v
        case "enabled": guard let v = value.asBool else { return false }; e.enabled = v
        case "lockedtopart": guard let v = value.asBool else { return false }; e.lockedToPart = v
        case "rate": guard let v = number(), v >= 0 else { return false }; e.rate = min(v, 1000)
        case "drag": guard let v = number() else { return false }; e.drag = v
        case "lightemission": guard let v = number() else { return false }; e.lightEmission = min(max(v, 0), 1)
        case "brightness": guard let v = number(), v >= 0 else { return false }; e.brightness = v
        case "timescale": guard let v = number() else { return false }; e.timeScale = min(max(v, 0), 1)
        case "lifetime": guard let v = range(), v.x >= 0 else { return false }; e.lifetime = v
        case "speed": guard let v = range() else { return false }; e.speed = v
        case "rotation": guard let v = range() else { return false }; e.rotation = v
        case "rotspeed": guard let v = range() else { return false }; e.rotSpeed = v
        case "spreadangle":
            guard let v = floats(), v.count == 2 else { return false }
            e.spreadAngle = SIMD2(v[0], v[1])
        case "acceleration":
            guard let v = floats(), v.count == 3 else { return false }
            e.acceleration = Vec3(v[0], v[1], v[2])
        case "size", "transparency":
            guard let v = floats(), v.count % 3 == 0 else { return false }
            let keys = stride(from: 0, to: v.count, by: 3).map { NumberKey(time: v[$0], value: v[$0 + 1], envelope: v[$0 + 2]) }
            guard ordered(keys.map(\.time)) else { return false }
            if key == "size" { e.size = keys } else { e.transparency = keys }
        case "color":
            guard let v = floats(), v.count % 4 == 0 else { return false }
            let keys = stride(from: 0, to: v.count, by: 4).map { ColorKey(time: v[$0], color: Vec3(v[$0 + 1], v[$0 + 2], v[$0 + 3])) }
            guard ordered(keys.map(\.time)) else { return false }
            e.color = keys
        case "emissiondirection":
            guard let v = value.asString.flatMap(ParticleEmitter.Face.init(rawValue:)) else { return false }
            e.emissionDirection = v
        case "texture": guard let v = value.asString else { return false }; e.texture = v
        default: return false
        }
        return true
    }
}
