import Foundation

// The script runtime's host calls for `sky.*`: Lighting's Sky, Atmosphere and Clouds
// (SkyObjects.swift). Scripts name the one in Lighting "L:<class>", and one in nothing
// (made, and not yet put in Lighting; or taken out) "-:<id>", kept in `looseSkyObjects`.

/// A Sky, Atmosphere or Clouds, wherever it is.
enum SkyObject {
    case sky(SkySettings)
    case atmosphere(AtmosphereSettings)
    case clouds(CloudSettings)

    static let classes = ["Sky", "Atmosphere", "Clouds"]

    init?(className: String) {
        switch className {
        case "Sky": self = .sky(SkySettings())
        case "Atmosphere": self = .atmosphere(AtmosphereSettings())
        case "Clouds": self = .clouds(CloudSettings())
        default: return nil
        }
    }

    var className: String {
        switch self {
        case .sky: return "Sky"
        case .atmosphere: return "Atmosphere"
        case .clouds: return "Clouds"
        }
    }

    /// Lighting's, of a class.
    static func inLighting(_ className: String, _ lighting: LightingSettings) -> SkyObject? {
        switch className {
        case "Sky": return lighting.skyObject.map(SkyObject.sky)
        case "Atmosphere": return lighting.atmosphere.map(SkyObject.atmosphere)
        case "Clouds": return lighting.clouds.map(SkyObject.clouds)
        default: return nil
        }
    }

    /// Puts it in Lighting (in place of any of its class there), or takes its class out.
    static func put(_ object: SkyObject?, className: String, into lighting: inout LightingSettings) {
        switch (className, object) {
        case ("Sky", .sky(let s)?): lighting.skyObject = s
        case ("Sky", _): lighting.skyObject = nil
        case ("Atmosphere", .atmosphere(let a)?): lighting.atmosphere = a
        case ("Atmosphere", _): lighting.atmosphere = nil
        case ("Clouds", .clouds(let c)?): lighting.clouds = c
        case ("Clouds", _): lighting.clouds = nil
        default: break
        }
    }

    func property(_ key: String) -> ScriptValue {
        func colour(_ c: Vec3) -> ScriptValue { .list([.number(Double(c.x)), .number(Double(c.y)), .number(Double(c.z))]) }
        switch self {
        case .sky(let s):
            if let face = SkySettings.Face.allCases.first(where: { $0.rawValue.lowercased() == key }) { return .string(s.picture(face)) }
            switch key {
            case "celestialbodiesshown": return .bool(s.celestialBodiesShown)
            case "starcount": return .number(Double(s.starCount))
            case "sunangularsize": return .number(Double(s.sunAngularSize))
            case "moonangularsize": return .number(Double(s.moonAngularSize))
            default: return .nothing
            }
        case .atmosphere(let a):
            switch key {
            case "density": return .number(Double(a.density))
            case "offset": return .number(Double(a.offset))
            case "glare": return .number(Double(a.glare))
            case "haze": return .number(Double(a.haze))
            case "color": return colour(a.color)
            case "decay": return colour(a.decay)
            default: return .nothing
            }
        case .clouds(let c):
            switch key {
            case "enabled": return .bool(c.enabled)
            case "cover": return .number(Double(c.cover))
            case "density": return .number(Double(c.density))
            case "color": return colour(c.color)
            default: return .nothing
            }
        }
    }

    /// Sets one, the Luau side having checked its type; numbers are kept in Roblox's range.
    mutating func set(_ key: String, _ value: ScriptValue) -> Bool {
        func number(_ range: ClosedRange<Float>) -> Float? {
            value.asFloat.flatMap { $0.isFinite ? min(max($0, range.lowerBound), range.upperBound) : nil }
        }
        func colour() -> Vec3? {
            guard case .list(let items) = value, items.count == 3 else { return nil }
            let v = items.compactMap(\.asFloat)
            return v.count == 3 ? Vec3(v[0], v[1], v[2]) : nil
        }
        switch self {
        case .sky(var s):
            if let face = SkySettings.Face.allCases.first(where: { $0.rawValue.lowercased() == key }) {
                guard let v = value.asString else { return false }
                s.setPicture(face, v)
            } else {
                switch key {
                case "celestialbodiesshown": guard let v = value.asBool else { return false }; s.celestialBodiesShown = v
                case "starcount": guard let v = number(0...5000) else { return false }; s.starCount = Int(v.rounded())
                case "sunangularsize": guard let v = number(0...60) else { return false }; s.sunAngularSize = v
                case "moonangularsize": guard let v = number(0...60) else { return false }; s.moonAngularSize = v
                default: return false
                }
            }
            self = .sky(s)
        case .atmosphere(var a):
            switch key {
            case "density": guard let v = number(0...1) else { return false }; a.density = v
            case "offset": guard let v = number(0...1) else { return false }; a.offset = v
            case "glare": guard let v = number(0...10) else { return false }; a.glare = v
            case "haze": guard let v = number(0...10) else { return false }; a.haze = v
            case "color": guard let v = colour() else { return false }; a.color = v
            case "decay": guard let v = colour() else { return false }; a.decay = v
            default: return false
            }
            self = .atmosphere(a)
        case .clouds(var c):
            switch key {
            case "enabled": guard let v = value.asBool else { return false }; c.enabled = v
            case "cover": guard let v = number(0...1) else { return false }; c.cover = v
            case "density": guard let v = number(0...1) else { return false }; c.density = v
            case "color": guard let v = colour() else { return false }; c.color = v
            default: return false
            }
            self = .clouds(c)
        }
        return true
    }
}

extension ScriptRuntime {
    func skyCall(_ name: String, _ arguments: [ScriptValue]) -> ScriptValue {
        switch name {
        case "sky.create":
            // In Lighting, or in nothing yet.
            guard let className = arguments.first?.asString, let object = SkyObject(className: className) else { return .nothing }
            if arguments.count > 1, arguments[1].asBool == true {
                model.lighting.update { SkyObject.put(object, className: className, into: &$0) }
                return .string("L:" + className)
            }
            let id = UUID()
            looseSkyObjects[id] = object
            return .string("-:" + id.uuidString)

        case "sky.find":
            guard let className = arguments.first?.asString,
                  SkyObject.inLighting(className, model.lighting) != nil else { return .nothing }
            return .string("L:" + className)

        case "sky.list":
            return .list(SkyObject.classes.filter { SkyObject.inLighting($0, model.lighting) != nil }.map { .string("L:" + $0) })

        case "sky.get":
            guard arguments.count > 1, let object = skyObject(arguments[0]), let key = arguments[1].asString?.lowercased() else {
                return .nothing
            }
            if key == "classname" { return .string(object.className) }
            if key == "parent" { return .bool(arguments[0].asString?.hasPrefix("L:") == true) }
            return object.property(key)

        case "sky.set":
            guard arguments.count > 2, var object = skyObject(arguments[0]), let key = arguments[1].asString?.lowercased(),
                  object.set(key, arguments[2]) else { return .bool(false) }
            store(object, as: arguments[0])
            return .bool(true)

        case "sky.parent":
            // Into Lighting (true) or out of it; its new name.
            guard let id = arguments.first, let object = skyObject(id) else { return .nothing }
            let toLighting = arguments.count > 1 && arguments[1].asBool == true
            remove(id)
            if toLighting {
                model.lighting.update { SkyObject.put(object, className: object.className, into: &$0) }
                return .string("L:" + object.className)
            }
            let loose = UUID()
            looseSkyObjects[loose] = object
            return .string("-:" + loose.uuidString)

        case "sky.destroy":
            if let id = arguments.first { remove(id) }
            return .nothing

        default:
            return unknownCall(name)
        }
    }

    private func skyObject(_ id: ScriptValue) -> SkyObject? {
        guard let text = id.asString else { return nil }
        if text.hasPrefix("L:") { return SkyObject.inLighting(String(text.dropFirst(2)), model.lighting) }
        return UUID(uuidString: String(text.dropFirst(2))).flatMap { looseSkyObjects[$0] }
    }

    private func store(_ object: SkyObject, as id: ScriptValue) {
        guard let text = id.asString else { return }
        if text.hasPrefix("L:") {
            model.lighting.update { SkyObject.put(object, className: object.className, into: &$0) }
        } else if let loose = UUID(uuidString: String(text.dropFirst(2))) {
            looseSkyObjects[loose] = object
        }
    }

    private func remove(_ id: ScriptValue) {
        guard let text = id.asString else { return }
        if text.hasPrefix("L:") {
            let className = String(text.dropFirst(2))
            model.lighting.update { SkyObject.put(nil, className: className, into: &$0) }
        } else if let loose = UUID(uuidString: String(text.dropFirst(2))) {
            looseSkyObjects[loose] = nil
        }
    }
}

extension LightingSettings {
    /// Changes it in place (a published value on the model: one change, one update).
    mutating func update(_ body: (inout LightingSettings) -> Void) { body(&self) }
}
