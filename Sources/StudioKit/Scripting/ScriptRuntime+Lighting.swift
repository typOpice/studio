import Foundation
import simd

// The script runtime's host calls for `light.*`, `lighting.*` and `click.*`: Lighting, and the
// PointLights and ClickDetectors kept in parts.
// `ScriptRuntime.invoke` routes each call here by the part of its name before the dot.

extension ScriptRuntime {
    /// Host calls for `light.*`, `lighting.*` and `click.*`: Lighting, PointLights, ClickDetectors.
    func lightingCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {

        // MARK: lighting
        case "lighting.get":
            return lightingProperty((arguments.first?.asString ?? "").lowercased())

        case "lighting.set":
            guard arguments.count >= 2 else { return .nothing }
            setLightingProperty((arguments[0].asString ?? "").lowercased(), arguments[1])
            return .nothing

        // MARK: ClickDetectors, one per part, kept the way lights are
        case "click.has":
            return .bool(part(arguments.first ?? .nothing)?.clickDetector != nil)

        case "click.create":
            guard let id = partID(arguments.first ?? .nothing) else { return .bool(false) }
            model.update(id: id) { if $0.clickDetector == nil { $0.clickDetector = ClickDetector() } }
            return .bool(true)

        case "click.destroy":
            guard let id = partID(arguments.first ?? .nothing) else { return .nothing }
            model.update(id: id) { $0.clickDetector = nil }
            return .nothing

        case "click.get":
            guard arguments.count >= 2, let detector = part(arguments[0])?.clickDetector else { return .nothing }
            return (arguments[1].asString ?? "").lowercased() == "maxactivationdistance"
                ? .number(Double(detector.maxActivationDistance)) : .nothing

        case "click.set":
            guard arguments.count >= 3, let id = partID(arguments[0]),
                  (arguments[1].asString ?? "").lowercased() == "maxactivationdistance",
                  let distance = arguments[2].asFloat else { return .nothing }
            model.update(id: id) { if $0.clickDetector != nil { $0.clickDetector!.maxActivationDistance = max(distance, 0) } }
            return .nothing

        case "light.create":
            let kind = arguments.first?.asString.flatMap(PointLight.Kind.init(rawValue:)) ?? .point
            let light = PointLight(kind: kind)
            looseLights[light.id] = light
            return .string(light.id.uuidString)

        case "light.get":
            guard arguments.count >= 2, let id = uuid(arguments.first), let light = findLight(id) else { return .nothing }
            if arguments[1].asString == "parent" {
                return model.lightParent(id).map { .string("p:" + $0.uuidString) } ?? .nothing
            }
            return Self.lightProperty(light, arguments[1].asString ?? "")

        case "light.set":
            guard arguments.count >= 3, let id = uuid(arguments.first), var light = findLight(id),
                  Self.setLightProperty(&light, arguments[1].asString ?? "", arguments[2]) else { return .bool(false) }
            if model.lightParent(id) != nil { model.updateLight(id) { $0 = light } }
            else { looseLights[id] = light }
            return .bool(true)

        case "light.parent":
            guard let id = uuid(arguments.first), let light = findLight(id) else { return .bool(false) }
            let parent = arguments.count > 1 ? uuid(arguments[1]) : nil
            guard parent == nil || model.part(id: parent!) != nil else { return .bool(false) }
            _ = takeLight(id)
            if let parent { model.update(id: parent) { $0.lights.append(light) } }
            else { looseLights[id] = light }
            return .bool(true)

        case "light.clone":
            guard let id = uuid(arguments.first), var copy = findLight(id) else { return .nothing }
            copy.id = UUID()
            looseLights[copy.id] = copy
            return .string(copy.id.uuidString)

        case "light.destroy":
            if let id = uuid(arguments.first) { _ = takeLight(id) }
            return .nothing

        default:
            return unknownCall(name)
        }
    }

    private func findLight(_ id: UUID) -> PointLight? { model.light(id) ?? looseLights[id] }

    private func takeLight(_ id: UUID) -> PointLight? {
        if let parent = model.lightParent(id), let light = model.light(id) {
            model.update(id: parent) { $0.lights.removeAll { $0.id == id } }
            return light
        }
        return looseLights.removeValue(forKey: id)
    }

    static func lightProperty(_ light: PointLight, _ property: String) -> ScriptValue {
        switch property {
        case "name": return .string(light.name)
        case "class": return .string(light.kind.rawValue)
        case "enabled": return .bool(light.enabled)
        case "color": return .triple(light.color.x, light.color.y, light.color.z)
        case "brightness": return .number(Double(light.brightness))
        case "range": return .number(Double(light.range))
        case "shadows": return .bool(light.shadows)
        case "angle": return .number(Double(light.angle))
        case "face": return .string(light.face.rawValue)
        default: return .nothing
        }
    }

    static func setLightProperty(_ light: inout PointLight, _ property: String, _ value: ScriptValue) -> Bool {
        func number() -> Float? { value.asFloat.flatMap { $0.isFinite ? $0 : nil } }
        switch property {
        case "name": guard let v = value.asString else { return false }; light.name = v
        case "enabled": guard let v = value.asBool else { return false }; light.enabled = v
        case "shadows": guard let v = value.asBool else { return false }; light.shadows = v
        case "brightness": guard let v = number() else { return false }; light.brightness = min(max(v, 0), 100)
        case "range": guard let v = number() else { return false }; light.range = min(max(v, 0), PointLight.maximumRange)
        case "angle": guard light.kind != .point, let v = number() else { return false }; light.angle = min(max(v, 0), 180)
        case "face":
            guard light.kind != .point, let face = value.asString.flatMap(ParticleEmitter.Face.init(rawValue:)) else { return false }
            light.face = face
        case "color":
            guard let (r, g, b) = value.asTriple, r.isFinite, g.isFinite, b.isFinite else { return false }
            light.color = simd_clamp(Vec3(r, g, b), Vec3.zero, Vec3(repeating: 1))
        default: return false
        }
        return true
    }

    func lightingProperty(_ name: String) -> ScriptValue {
        let lighting = model.lighting
        func color(_ v: Vec3) -> ScriptValue { .triple(v.x, v.y, v.z) }
        switch name {
        case "clocktime": return .number(Double(LightingSettings.wrapHours(lighting.clockTime)))
        case "timeofday": return .string(lighting.timeOfDay)
        case "brightness": return .number(Double(lighting.brightness))
        case "ambient": return color(lighting.ambient)
        case "outdoorambient": return color(lighting.outdoorAmbient)
        case "colorshift_top": return color(lighting.colorShiftTop)
        case "globalshadows": return .bool(lighting.globalShadows)
        case "shadowsoftness": return .number(Double(lighting.shadowSoftness))
        case "exposurecompensation": return .number(Double(lighting.exposureCompensation))
        case "fogcolor": return color(lighting.fogColor)
        case "fogstart": return .number(Double(lighting.fogStart))
        case "fogend": return .number(Double(lighting.fogEnd))
        case "geographiclatitude": return .number(Double(lighting.geographicLatitude))
        case "technology": return .string(lighting.technology.rawValue)
        case "sundirection": return color(lighting.sunDirection)
        default: return .nothing
        }
    }

    func setLightingProperty(_ name: String, _ value: ScriptValue) {
        func color() -> Vec3? {
            value.asTriple.map { Vec3(min(max($0.0, 0), 1), min(max($0.1, 0), 1), min(max($0.2, 0), 1)) }
        }
        var lighting = model.lighting
        switch name {
        case "clocktime": if let v = value.asFloat { lighting.clockTime = LightingSettings.wrapHours(v) }
        case "timeofday":
            if let text = value.asString, let hours = LightingSettings.hours(fromTimeOfDay: text) {
                lighting.clockTime = LightingSettings.wrapHours(hours)
            }
        case "brightness": if let v = value.asFloat { lighting.brightness = min(max(v, 0), 10) }
        case "ambient": if let c = color() { lighting.ambient = c }
        case "outdoorambient": if let c = color() { lighting.outdoorAmbient = c }
        case "colorshift_top": if let c = color() { lighting.colorShiftTop = c }
        case "globalshadows": if let b = value.asBool { lighting.globalShadows = b }
        case "shadowsoftness": if let v = value.asFloat { lighting.shadowSoftness = min(max(v, 0), 1) }
        case "exposurecompensation": if let v = value.asFloat { lighting.exposureCompensation = min(max(v, -3), 3) }
        case "fogcolor": if let c = color() { lighting.fogColor = c }
        case "fogstart": if let v = value.asFloat { lighting.fogStart = max(v, 0) }
        case "fogend": if let v = value.asFloat { lighting.fogEnd = max(v, 0) }
        case "geographiclatitude": if let v = value.asFloat { lighting.geographicLatitude = min(max(v, -90), 90) }
        case "technology":
            if let raw = value.asString, let technology = LightingTechnology(rawValue: raw) {
                lighting.technology = technology
            }
        default: return
        }
        if lighting != model.lighting { model.lighting = lighting }
    }
}
