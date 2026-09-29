import Foundation
import simd

/// A small, fully scripted race built from the Toolbox's real hinge-driven cars.
enum Racing {
    static let name = "Crash Circuit"
    static let placeID = UUID(uuidString: "ACE00001-0000-4000-8000-000000000001")!
    static let colors = [Vec3(0.96, 0.25, 0.18), Vec3(0.12, 0.55, 0.95), Vec3(0.96, 0.73, 0.12), Vec3(0.55, 0.3, 0.9)]
    static func point(_ angle: Float) -> Vec3 { Vec3(100 * cos(angle), 0, -75 * sin(angle)) }
    static func state() -> SceneState {
        var builder = Builder(); builder.build()
        let model = SceneModel(); model.state = builder.state
        for index in 0..<4 {
            model.insert(.car, at: Vec3(index % 2 == 0 ? 92 : 108, 0.25, Float(index / 2) * 17 + 8))
            guard let id = model.selection.first, let groupIndex = model.groups.firstIndex(where: { $0.id == id }) else { continue }
            model.groups[groupIndex].name = "Racer\(index + 1)"
            model.groups[groupIndex].primaryPartID = model.parts.first { $0.parentID == id && $0.name == "Body" }?.id
            for i in model.parts.indices where model.parts[i].parentID == id {
                model.parts[i].anchored = true
                if ["Body", "Hood", "Bumper"].contains(model.parts[i].name) { model.parts[i].color = colors[index] }
                if model.parts[i].name == "VehicleSeat" {
                    model.parts[i].seat?.vehicle?.maxSpeed = 38; model.parts[i].seat?.vehicle?.headsUpDisplay = false
                }
                if model.parts[i].name == "Body" {
                    var sparks = ParticleEmitter(); sparks.name = "CrashSparks"; sparks.enabled = false
                    sparks.texture = "builtin://Sparkle"; sparks.lifetime = SIMD2(0.3, 0.7); sparks.speed = SIMD2(8, 16)
                    sparks.spreadAngle = SIMD2(80, 80); sparks.acceleration = Vec3(0, -20, 0)
                    sparks.size = .from(0.35, to: 0); sparks.transparency = .from(0, to: 1)
                    sparks.color = .from(Vec3(1, 0.85, 0.2), to: Vec3(1, 0.25, 0.05)); sparks.lightEmission = 1
                    var smoke = ParticleEmitter(); smoke.name = "DamageSmoke"; smoke.enabled = false
                    smoke.texture = "builtin://Smoke"; smoke.rate = 8; smoke.lifetime = SIMD2(1, 2)
                    smoke.speed = SIMD2(2, 4); smoke.size = .from(0.5, to: 2.5); smoke.transparency = .from(0.3, to: 1)
                    smoke.color = .from(Vec3(repeating: 0.2), to: Vec3(repeating: 0.5))
                    model.parts[i].emitters = [sparks, smoke]
                }
                if model.parts[i].name == "Hood" {
                    var headlight = PointLight(kind: .spot)
                    headlight.name = "Headlights"; headlight.face = .front; headlight.angle = 65
                    headlight.range = 45; headlight.brightness = 3; headlight.color = Vec3(1, 0.93, 0.72)
                    model.parts[i].lights.append(headlight)
                }
            }
            let body = model.parts.first { $0.parentID == id && $0.name == "Body" }!
            var crash = SceneSound(name: "Crash", parentID: body.id); crash.soundId = "builtin://Hit"; crash.volume = 0.8; model.sounds.append(crash)
            for (name, kind, number, text) in [("Health", DataClass.intValue, 100.0, ""), ("Lap", .intValue, 1.0, ""), ("NextGate", .intValue, 2.0, ""), ("Place", .intValue, 0.0, ""), ("Driver", .stringValue, 0.0, "NPC \(index + 1)")] {
                var object = DataObject(name: name, className: kind, parent: .node(id)); object.number = number; object.text = text; model.dataObjects.append(object)
            }
        }
        // The start arch is a real union with a subtractive opening.
        var arch = Part(); arch.name = "ArchBlank"; arch.position = Vec3(100, 8, -8); arch.size = Vec3(42, 16, 2); arch.color = Vec3(0.94, 0.74, 0.16)
        var opening = Part(); opening.position = Vec3(100, 6, -8); opening.size = Vec3(36, 12, 4); opening.negative = true
        model.parts += [arch, opening]
        if let id = try? model.makeUnion([arch.id, opening.id]) { model.update(id: id) { $0.name = "StartArch" } }
        model.selection = []; model.placeID = placeID
        model.starterPlayer.respawnTime = 1
        model.starterPlayer.cameraMaxZoomDistance = 60
        model.clearHistory()
        return model.state
    }

    struct Builder: PlaceBuilding {
        var state = SceneState(), seed: UInt32 = 713
        mutating func build() {
            state.lighting.clockTime = 17.4; state.lighting.brightness = 2.2
            state.lighting.ambient = Vec3(0.28, 0.30, 0.36); state.lighting.fogStart = 350; state.lighting.fogEnd = 650
            let hud = DefaultHud.makeLeaderboard()
            state.starterGui = hud.objects; state.scripts = hud.scripts + [UtilsModule.make()]; state.defaultGui = DefaultHud.version
            // Keep chat compact and clear of the centered race banner and the road.
            var chat = CoreScripts.chatScript; chat.id = UUID()
            chat.source = chat.source.replacingOccurrences(of: "local TOP = 16", with: "local TOP = 110")
                .replacingOccurrences(of: "local WIDTH = 400", with: "local WIDTH = 250")
                .replacingOccurrences(of: "local HEIGHT = 176", with: "local HEIGHT = 76")
            state.scripts.append(chat)
            part("Infield", Vec3(0, -0.4, 0), Vec3(340, 1, 290), Vec3(0.15, 0.32, 0.22))
            let road = group("Circuit", kind: .folder)
            for index in 0..<32 {
                let a = Float(index) * 2 * .pi / 32, b = Float(index + 1) * 2 * .pi / 32
                let p = Racing.point(a), q = Racing.point(b), middle = (p + q) / 2
                let yaw = atan2(q.x - p.x, q.z - p.z) * 180 / .pi
                part("Track", middle + Vec3(0, 0.02, 0), Vec3(38, 0.4, simd_distance(p, q) + 5), Vec3(0.13, 0.15, 0.19), rotation: Vec3(0, yaw, 0), in: road)
                for radius: Float in [-23, 23] {
                    let p = Vec3((100 + radius) * cos(a), 2, -(75 + radius) * sin(a))
                    let q = Vec3((100 + radius) * cos(b), 2, -(75 + radius) * sin(b))
                    let wallYaw = atan2(q.x - p.x, q.z - p.z) * 180 / .pi
                    part("Barrier", (p + q) / 2, Vec3(1.5, 4, simd_distance(p, q) + 0.4), index % 2 == 0 ? Vec3(0.88, 0.22, 0.18) : Vec3(repeating: 0.88), rotation: Vec3(0, wallYaw, 0), in: road)
                }
                part("Route\(index + 1)", p + Vec3(0, 0.5, 0), Vec3(repeating: 0.1), .zero, in: road, collide: false, transparency: 1)
            }
            let gates = group("RaceGates", kind: .folder)
            for i in 0..<8 {
                let angle = Float(i) * 2 * .pi / 8
                part("Gate\(i + 1)", Racing.point(angle) + Vec3(0, 0.3, 0), Vec3(36, 0.08, 1.3), i == 0 ? Vec3(repeating: 0.98) : Vec3(0.9, 0.67, 0.18), rotation: Vec3(0, angle * 180 / .pi, 0), in: gates, collide: false)
            }
            part("StartSign", Vec3(100, 15, -6.7), Vec3(30, 5, 0.5), Vec3(0.05, 0.09, 0.15))
            let lamp = part("StartLights", Vec3(100, 12.8, -8), Vec3(28, 0.3, 1), Vec3(1, 0.87, 0.45), material: .neon)
            if let i = state.parts.firstIndex(where: { $0.id == lamp }) {
                var light = PointLight(kind: .surface); light.face = .bottom; light.angle = 110; light.range = 26; light.brightness = 2
                state.parts[i].lights = [light]
            }
            for i in 0..<5 {
                part("Grandstand", Vec3(151 + Float(i) * 3, Float(i) * 2 + 1, 0), Vec3(3, 2, 55), Vec3(0.25, 0.33, 0.43))
            }
            var race = DataObject(name: "RaceState", className: .folder, parent: .replicatedStorage)
            race.flag = false; state.dataObjects.append(race)
            for (name, kind, number, text) in [("Phase", DataClass.stringValue, 0.0, "GRID"), ("Countdown", .intValue, 4.0, ""), ("Round", .intValue, 1.0, ""), ("Message", .stringValue, 0.0, "Four cars. Three laps. Keep the wheels on.")] {
                var value = DataObject(name: name, className: kind, parent: .node(race.id)); value.number = number; value.text = text; state.dataObjects.append(value)
            }
            state.dataObjects.append(DataObject(name: "RecoverCar", className: .remoteEvent, parent: .replicatedStorage))
            script("RaceRules", RacingScripts.rules)
            script("RaceDashboard", RacingScripts.dashboard, host: .starterPlayer)
            sound("RaceMusic", "builtin://CalmDay", volume: 0.12, looped: true, playing: true)
            sound("RaceGo", "builtin://Chime", volume: 0.7)
        }
    }
}
