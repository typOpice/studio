import Foundation
import simd

/// Adventure Island: a small open-world game made only of what Studio offers, to play
/// and to take apart. A plaza to start from; a village with a gem-trading baker; the
/// Obby Tower (lava, a moving platform, a spinner, a truss, vanishing tiles, a jump pad,
/// checkpoints); the Mirror Lab, whose lever switches ray tracing on for its mirrors,
/// chrome and coloured lights; the Crystal Caves and the Dream Garden, with surface
/// shaders on what's there and a screen effect while you're inside; a lake to swim
/// (underwater tint); a lighthouse to climb; woods; eight NPCs to talk to, five gems to
/// find, and a leaderboard. The scripts — ModuleScripts, RemoteEvents, leaderstats,
/// accessories — are in AdventureIslandScripts.swift.
enum AdventureIsland {
    static let name = "Adventure Island"

    /// The whole place, ready to open or save.
    static func state() -> SceneState {
        var builder = Builder()
        builder.build()
        return builder.state
    }

    /// Everything's colours, by name.
    static func rgb(_ r: Float, _ g: Float, _ b: Float) -> Vec3 { Vec3(r, g, b) / 255 }

    // MARK: - Building

    struct Builder {
        var state = SceneState()
        /// A repeatable scatter: trees and rocks land in the same places every time.
        private var seed: UInt32 = 20_260_926

        mutating func random(_ low: Float, _ high: Float) -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return low + Float(seed >> 8) / Float(1 << 24) * (high - low)
        }

        @discardableResult
        mutating func part(_ name: String, _ position: Vec3, _ size: Vec3, _ color: Vec3,
                           shape: PartShape = .block, material: PartMaterial = .plastic, rotation: Vec3 = .zero,
                           in parent: UUID? = nil, collide: Bool = true, transparency: Float = 0,
                           shader: UUID? = nil, light: PointLight? = nil) -> UUID {
            var part = Part()
            part.name = name
            part.shape = shape
            part.position = position
            part.size = size
            part.color = color
            part.material = material
            part.rotationDegrees = rotation
            part.parentID = parent
            part.canCollide = collide
            part.transparency = transparency
            part.shaderID = shader
            part.light = light
            state.parts.append(part)
            return part.id
        }

        mutating func group(_ name: String, kind: SceneGroup.Kind = .model, in parent: UUID? = nil) -> UUID {
            let group = SceneGroup(name: name, kind: kind, parentID: parent)
            state.groups.append(group)
            return group.id
        }

        mutating func script(_ name: String, _ source: String, in parent: UUID? = nil, host: ScriptHost = .scene,
                             module: Bool = false) {
            var script = ScriptObject.blank(language: .luau)
            script.name = name
            script.source = source
            script.host = host
            script.parentID = parent
            if module { script.kind = .module }
            state.scripts.append(script)
        }

        mutating func shader(_ name: String, _ kind: ShaderKind, _ source: String, _ parameters: [(String, Float)]) -> UUID {
            var shader = ShaderObject.blank(kind: kind)
            shader.name = name
            shader.source = source
            shader.parameters = parameters.map { ShaderParameter(name: $0.0, value: $0.1) }
            state.shaders.append(shader)
            return shader.id
        }

        mutating func light(_ color: Vec3, brightness: Float = 2, range: Float = 16, shadows: Bool = false) -> PointLight {
            var light = PointLight()
            light.color = color
            light.brightness = brightness
            light.range = range
            light.shadows = shadows
            return light
        }

        /// A sign: a post and a board, with what it says in a StringValue for the
        /// Adventure script to show over it.
        mutating func sign(_ name: String, at position: Vec3, text: String, signs: UUID) {
            let wood = rgb(120, 84, 52)
            part(name + "Post", position + Vec3(0, 2, 0), Vec3(0.5, 4, 0.5), wood, shape: .cylinder, material: .wood,
                 in: signs)
            let board = part(name, position + Vec3(0, 4.2, 0), Vec3(4, 1.6, 0.3), rgb(196, 160, 110), material: .wood,
                             in: signs)
            var value = DataObject(name: "Text", className: .stringValue, parent: .node(board))
            value.text = text
            state.dataObjects.append(value)
        }

        // MARK: The whole island

        mutating func build() {
            state.lighting = lighting()
            state.starterPlayer.respawnTime = 2
            shaders()
            ground()
            plaza()
            village()
            obby()
            mirrorLab()
            caves()
            dreamGarden()
            lake()
            lighthouse()
            woods()
            npcs()
            gems()
            signs()
            chime()
            data()
            scripts()
            hud()
            state.defaultGui = DefaultHud.version
        }

        func lighting() -> LightingSettings {
            var lighting = LightingSettings()
            lighting.clockTime = 15.5
            lighting.brightness = 2.2
            lighting.shadowSoftness = 0.25
            lighting.outdoorAmbient = rgb(140, 140, 150)
            lighting.fogColor = rgb(190, 214, 235)
            lighting.fogStart = 160
            lighting.fogEnd = 460
            return lighting
        }

        // Shaders are made first, so parts can name them.
        private(set) var crystal = UUID(), rainbow = UUID(), lava = UUID(), ripple = UUID()

        mutating func shaders() {
            crystal = shader("Crystal", .surface, AdventureIslandScripts.crystalShader, [("speed", 1.2), ("glow", 1)])
            rainbow = shader("Rainbow", .surface, AdventureIslandScripts.rainbowShader, [("speed", 1)])
            lava = shader("Lava", .surface, AdventureIslandScripts.lavaShader, [("speed", 1.4)])
            ripple = shader("Ripple", .surface, AdventureIslandScripts.rippleShader, [("speed", 1.2)])
            _ = shader("Cave Glow", .screen, AdventureIslandScripts.caveGlowShader, [("amount", 1)])
            _ = shader("Dreamy", .screen, AdventureIslandScripts.dreamyShader, [("amount", 1)])
            _ = shader("Underwater", .screen, AdventureIslandScripts.underwaterShader, [("amount", 1)])
        }

        mutating func ground() {
            // Its top a little above the ground plane (and Studio's grid) at 0, so they never fight.
            part("Ground", Vec3(0, -0.8, 0), Vec3(1600, 2, 1600), rgb(92, 150, 76), material: .smooth)
            // Sand paths out from the plaza.
            let paths = group("Paths", kind: .folder)
            let sand = rgb(214, 196, 150)
            part("ToVillage", Vec3(0, 0.25, 43), Vec3(6, 0.1, 34), sand, material: .smooth, in: paths)
            part("ToObby", Vec3(-28.5, 0.25, 10), Vec3(25, 0.1, 6), sand, material: .smooth, in: paths)
            part("ToLab", Vec3(40.5, 0.25, 10), Vec3(48, 0.1, 6), sand, material: .smooth, in: paths)
            part("ToCaves", Vec3(0, 0.25, -39), Vec3(6, 0.1, 64), sand, material: .smooth, in: paths)
            part("ToGarden", Vec3(-37, 0.25, 47), Vec3(6, 0.1, 72), sand, material: .smooth, rotation: Vec3(0, -45, 0),
                 in: paths)
            part("ToLake", Vec3(36, 0.25, 47), Vec3(6, 0.1, 72), sand, material: .smooth, rotation: Vec3(0, 45, 0),
                 in: paths)
            part("ToLighthouse", Vec3(46, 0.25, -41), Vec3(6, 0.1, 106), sand, material: .smooth,
                 rotation: Vec3(0, -41, 0), in: paths)
        }

        mutating func plaza() {
            let plaza = group("Plaza")
            let stone = rgb(190, 186, 176)
            part("PlazaFloor", Vec3(0, 0.2, 10), Vec3(34, 0.4, 34), stone, shape: .cylinder, material: .smooth, in: plaza)
            part("FountainBasin", Vec3(0, 0.9, 2), Vec3(10, 1.4, 10), rgb(170, 166, 158), shape: .cylinder, in: plaza)
            part("FountainWater", Vec3(0, 1.62, 2), Vec3(8.8, 0.1, 8.8), rgb(80, 170, 220), shape: .cylinder,
                 in: plaza, collide: false, shader: ripple)
            part("FountainColumn", Vec3(0, 3.6, 2), Vec3(1.4, 4, 1.4), stone, shape: .cylinder, in: plaza)
            part("FountainBowl", Vec3(0, 5.8, 2), Vec3(4.4, 0.6, 4.4), stone, shape: .cylinder, in: plaza)
            part("FountainOrb", Vec3(0, 7, 2), Vec3(1.4, 1.4, 1.4), rgb(120, 230, 255), shape: .sphere, material: .neon,
                 in: plaza, light: light(rgb(120, 220, 255), brightness: 2, range: 14))
            // Benches round the plaza.
            for angle in stride(from: Float(45), to: 360, by: 90) {
                let radians = angle * .pi / 180
                let at = Vec3(sin(radians) * 12, 0, 10 + cos(radians) * 12)
                var seat = Part()
                seat.name = "Bench"
                seat.position = at + Vec3(0, 1, 0)
                seat.size = Vec3(4, 0.6, 1.6)
                seat.color = rgb(130, 90, 56)
                seat.material = .wood
                seat.rotationDegrees = Vec3(0, angle, 0)
                seat.parentID = plaza
                seat.seat = SeatSettings()
                state.parts.append(seat)
                part("BenchLegs", at + Vec3(0, 0.35, 0), Vec3(3.4, 0.7, 1.2), rgb(90, 90, 96), rotation: Vec3(0, angle, 0),
                     in: plaza)
            }
            // Lamp posts.
            for (x, z) in [(Float(-14), Float(-4)), (14, -4), (-14, 24), (14, 24)] {
                part("LampPost", Vec3(x, 3, z), Vec3(0.5, 6, 0.5), rgb(60, 60, 66), shape: .cylinder, material: .metal,
                     in: plaza)
                part("LampGlobe", Vec3(x, 6.4, z), Vec3(1.2, 1.2, 1.2), rgb(255, 230, 170), shape: .sphere, material: .neon,
                     in: plaza, light: light(rgb(255, 214, 150), brightness: 1.5, range: 12))
            }
        }

        mutating func house(_ name: String, at centre: Vec3, facing sign: Float, colour: Vec3, roof: Vec3, in parent: UUID) {
            let house = group(name, in: parent)
            part("Walls", centre + Vec3(0, 3.5, 0), Vec3(12, 7, 10), colour, in: house)
            part("RoofNorth", centre + Vec3(0, 8.5, -2.5), Vec3(12.6, 3, 5.4), roof, shape: .wedge, rotation: Vec3(0, 180, 0),
                 in: house)
            part("RoofSouth", centre + Vec3(0, 8.5, 2.5), Vec3(12.6, 3, 5.4), roof, shape: .wedge, in: house)
            part("Door", centre + Vec3(sign * 6.05, 2, 0), Vec3(0.2, 4, 2.4), rgb(92, 60, 38), material: .wood, in: house)
            for z in [Float(-3.2), 3.2] {
                part("Window", centre + Vec3(sign * 6.05, 4.2, z), Vec3(0.2, 1.6, 1.8), rgb(255, 226, 160),
                     material: .neon, in: house)
            }
            part("Chimney", centre + Vec3(-3, 10, -2), Vec3(1.2, 3, 1.2), rgb(120, 70, 60), in: house)
        }

        mutating func village() {
            let village = group("Village")
            house("BakeryHouse", at: Vec3(-18, 0, 64), facing: 1, colour: rgb(238, 214, 170), roof: rgb(170, 70, 50), in: village)
            house("MarasHouse", at: Vec3(-18, 0, 90), facing: 1, colour: rgb(200, 220, 236), roof: rgb(70, 90, 130), in: village)
            house("MillHouse", at: Vec3(18, 0, 64), facing: -1, colour: rgb(230, 190, 190), roof: rgb(110, 60, 70), in: village)
            house("InnHouse", at: Vec3(18, 0, 90), facing: -1, colour: rgb(210, 230, 190), roof: rgb(80, 110, 60), in: village)
            // The square, and the market stall where Baker Bo sells bread.
            part("Square", Vec3(0, 0.2, 77), Vec3(22, 0.2, 36), rgb(180, 170, 150), material: .smooth, in: village)
            let stall = group("MarketStall", in: village)
            for (x, z) in [(Float(-3.6), Float(94)), (3.6, 94), (-3.6, 99), (3.6, 99)] {
                part("Post", Vec3(x, 2.5, z), Vec3(0.4, 5, 0.4), rgb(120, 84, 52), material: .wood, in: stall)
            }
            part("AwningRed", Vec3(-1.9, 5.2, 96.5), Vec3(3.8, 0.3, 6), rgb(210, 60, 60), in: stall)
            part("AwningWhite", Vec3(1.9, 5.2, 96.5), Vec3(3.8, 0.3, 6), rgb(245, 245, 240), in: stall)
            part("Counter", Vec3(0, 1.2, 94), Vec3(8, 2.4, 1.4), rgb(150, 104, 64), material: .wood, in: stall)
            for x in [Float(-2.4), 0, 2.4] {
                part("Loaf", Vec3(x, 2.65, 94), Vec3(1.4, 0.5, 0.8), rgb(214, 150, 70), shape: .sphere, in: stall)
            }
            // A well.
            part("Well", Vec3(8, 1, 74), Vec3(4, 2, 4), rgb(150, 146, 140), shape: .cylinder, in: village)
            part("WellWater", Vec3(8, 2.02, 74), Vec3(3, 0.05, 3), rgb(60, 130, 190), shape: .cylinder, in: village,
                 collide: false)
            part("WellRoof", Vec3(8, 5, 74), Vec3(5, 0.4, 5), rgb(110, 60, 50), in: village)
            for x in [Float(6.2), 9.8] {
                part("WellPost", Vec3(x, 3.5, 74), Vec3(0.3, 3, 0.3), rgb(120, 84, 52), material: .wood, in: village)
            }
            for (x, z) in [(Float(-6), Float(58)), (6, 58), (-6, 96), (6, 106)] {
                part("StreetLamp", Vec3(x, 3, z), Vec3(0.4, 6, 0.4), rgb(60, 60, 66), shape: .cylinder, material: .metal,
                     in: village)
                part("StreetLight", Vec3(x, 6.3, z), Vec3(1, 1, 1), rgb(255, 214, 150), shape: .sphere, material: .neon,
                     in: village, light: light(rgb(255, 200, 130), brightness: 1.2, range: 12))
            }
        }

        mutating func obby() {
            let obby = group("Obby")
            let stone = rgb(150, 150, 160), green = rgb(80, 230, 120)
            part("Start", Vec3(-45, 0.5, 10), Vec3(10, 1, 10), stone, in: obby)
            part("Lava", Vec3(-88, 0.4, 10), Vec3(76, 0.8, 16), rgb(255, 110, 30), material: .neon, in: obby,
                 shader: lava)
            // Stage 1: stepping stones.
            for (index, (x, z)) in [(Float(-54), Float(8)), (-60.5, 12), (-67, 9), (-73.5, 11)].enumerated() {
                part("Stone\(index + 1)", Vec3(x, 2.5, z), Vec3(3.5, 1, 3.5), stone, shape: .cylinder, in: obby)
            }
            part("Platform1", Vec3(-80, 2.5, 10), Vec3(8, 1, 8), stone, in: obby)
            part("Checkpoint1", Vec3(-80, 3.1, 10), Vec3(4, 0.2, 4), green, material: .neon, in: obby, collide: false)
            // Stage 2: a platform that glides across; stage 3: a spinning bar to jump.
            part("Mover", Vec3(-88.5, 2.5, 10), Vec3(5, 1, 5), rgb(90, 160, 230), material: .metal, in: obby)
            part("SpinDisc", Vec3(-112, 2.5, 10), Vec3(14, 1, 14), stone, shape: .cylinder, in: obby)
            part("SpinHub", Vec3(-112, 4, 10), Vec3(1.4, 2, 1.4), rgb(70, 70, 80), shape: .cylinder, material: .metal,
                 in: obby)
            part("Spinner", Vec3(-112, 3.6, 10), Vec3(13, 0.8, 0.8), rgb(255, 60, 50), material: .neon, in: obby)
            part("Platform2", Vec3(-126, 2.5, 10), Vec3(8, 1, 8), stone, in: obby)
            part("Checkpoint2", Vec3(-126, 3.1, 10), Vec3(4, 0.2, 4), green, material: .neon, in: obby, collide: false)
            // Stage 4: climb the truss to the high deck.
            part("Truss", Vec3(-126, 10.5, 5), Vec3(2, 15, 2), rgb(120, 120, 130), shape: .truss, material: .metal, in: obby)
            part("Deck", Vec3(-126, 18.5, 0), Vec3(8, 1, 8), stone, in: obby)
            part("Checkpoint3", Vec3(-126, 19.1, 0), Vec3(4, 0.2, 4), green, material: .neon, in: obby, collide: false)
            // Stage 5: tiles that give way, then the jump pad up to the summit.
            for (index, x) in [Float(-119), -113, -107, -101].enumerated() {
                part("Tile\(index + 1)", Vec3(x, 18.5, 0), Vec3(4, 1, 4), rgb(230, 200, 90), in: obby)
            }
            part("PadPlatform", Vec3(-92, 18.5, 0), Vec3(6, 1, 6), stone, in: obby)
            part("JumpPad", Vec3(-92, 19.1, 0), Vec3(4, 0.2, 4), rgb(80, 160, 255), material: .neon, in: obby, collide: false)
            part("Summit", Vec3(-92, 34, -12), Vec3(12, 1, 12), rgb(240, 220, 150), in: obby)
            part("TrophyBase", Vec3(-92, 35.5, -14), Vec3(2.4, 2, 2.4), rgb(80, 60, 40), shape: .cylinder, in: obby)
            part("Trophy", Vec3(-92, 37.4, -14), Vec3(1.8, 1.8, 1.8), rgb(255, 205, 60), shape: .sphere, material: .neon,
                 in: obby, collide: false, light: light(rgb(255, 210, 90), brightness: 2, range: 14))
        }

        mutating func mirrorLab() {
            let lab = group("MirrorLab")
            let wall = rgb(40, 42, 50), mirror = rgb(235, 238, 245)
            part("LabFloor", Vec3(85, 0.2, 10), Vec3(40, 0.4, 40), rgb(26, 26, 32), material: .metal, in: lab)
            part("NorthWall", Vec3(85, 7, -10.5), Vec3(42, 14, 1), wall, in: lab)
            part("SouthWall", Vec3(85, 7, 30.5), Vec3(42, 14, 1), wall, in: lab)
            part("EastWall", Vec3(105.5, 7, 10), Vec3(1, 14, 40), wall, in: lab)
            part("WestWallNorth", Vec3(64.5, 7, -2.5), Vec3(1, 14, 17), wall, in: lab)
            part("WestWallSouth", Vec3(64.5, 7, 22.5), Vec3(1, 14, 17), wall, in: lab)
            part("DoorLintel", Vec3(64.5, 11.5, 10), Vec3(1, 5, 8), wall, in: lab)
            part("LabRoof", Vec3(85, 14.5, 10), Vec3(44, 1, 44), rgb(30, 30, 36), in: lab)
            part("LabSign", Vec3(63.8, 11.5, 10), Vec3(0.3, 2, 7), rgb(80, 230, 255), material: .neon, in: lab)
            // Mirrors down each side, turned a little.
            for (index, x) in [Float(74), 85, 96].enumerated() {
                part("MirrorN\(index + 1)", Vec3(x, 5.5, -9), Vec3(8, 9, 0.4), mirror, material: .metal,
                     rotation: Vec3(0, index % 2 == 0 ? 12 : -12, 0), in: lab)
                part("MirrorS\(index + 1)", Vec3(x, 5.5, 29), Vec3(8, 9, 0.4), mirror, material: .metal,
                     rotation: Vec3(0, index % 2 == 0 ? -12 : 12, 0), in: lab)
            }
            part("MirrorE", Vec3(104, 5.5, 10), Vec3(0.4, 9, 14), mirror, material: .metal, in: lab)
            // The chrome orb, glass pillars, neon strips along the floor, coloured lamps.
            part("ChromeOrb", Vec3(88, 5, 10), Vec3(6, 6, 6), rgb(230, 232, 240), shape: .sphere, material: .metal, in: lab)
            part("OrbStand", Vec3(88, 1, 10), Vec3(3, 1.6, 3), rgb(50, 50, 60), shape: .cylinder, material: .metal, in: lab)
            for (x, z) in [(Float(76), Float(0)), (76, 20), (98, 0), (98, 20)] {
                part("GlassPillar", Vec3(x, 6, z), Vec3(2, 12, 2), rgb(170, 220, 255), shape: .cylinder, in: lab,
                     transparency: 0.55)
            }
            let strips: [(String, Vec3, Vec3)] = [("StripNorth", Vec3(85, 0.45, -8), Vec3(36, 0.1, 0.4)),
                                                  ("StripSouth", Vec3(85, 0.45, 28), Vec3(36, 0.1, 0.4)),
                                                  ("StripEast", Vec3(103, 0.45, 10), Vec3(0.4, 0.1, 36))]
            for (name, at, size) in strips {
                part(name, at, size, rgb(90, 220, 255), material: .neon, in: lab)
            }
            let lamps: [(Vec3, Vec3)] = [(Vec3(70, 11, -5), rgb(255, 70, 90)), (Vec3(100, 11, -5), rgb(80, 140, 255)),
                                         (Vec3(70, 11, 25), rgb(90, 255, 140)), (Vec3(100, 11, 25), rgb(255, 120, 255))]
            for (index, lamp) in lamps.enumerated() {
                part("Lamp\(index + 1)", lamp.0, Vec3(1.6, 1.6, 1.6), lamp.1, shape: .sphere, material: .neon, in: lab,
                     light: light(lamp.1, brightness: 3, range: 26, shadows: true))
            }
            // The lever that switches ray tracing, its status light, and the light-show button.
            part("Pedestal", Vec3(71, 1.5, 10), Vec3(2.4, 3, 2.4), rgb(70, 72, 84), material: .metal, in: lab)
            part("Lever", Vec3(71, 4, 10), Vec3(0.4, 2.2, 0.4), rgb(230, 230, 235), shape: .cylinder, material: .metal,
                 rotation: Vec3(0, 0, 35), in: lab)
            part("StatusLight", Vec3(71, 3.2, 8.4), Vec3(0.8, 0.8, 0.8), rgb(255, 70, 60), shape: .sphere,
                 material: .neon, in: lab)
            part("ShowPedestal", Vec3(71, 1.5, 4), Vec3(2, 3, 2), rgb(70, 72, 84), material: .metal, in: lab)
            part("ShowButton", Vec3(71, 3.2, 4), Vec3(1.4, 0.4, 1.4), rgb(255, 60, 60), shape: .cylinder,
                 material: .neon, in: lab)
        }

        mutating func caves() {
            let caves = group("CrystalCaves")
            let rock = rgb(84, 80, 90), dark = rgb(58, 56, 64)
            part("CaveFloor", Vec3(0, 0.2, -95), Vec3(42, 0.4, 48), dark, in: caves)
            part("CaveWest", Vec3(-21, 8, -95), Vec3(3, 16, 48), rock, rotation: Vec3(0, 0, -4), in: caves)
            part("CaveEast", Vec3(21, 8, -95), Vec3(3, 16, 48), rock, rotation: Vec3(0, 0, 4), in: caves)
            part("CaveBack", Vec3(0, 8, -119), Vec3(44, 16, 3), rock, in: caves)
            part("CaveFrontWest", Vec3(-13, 8, -71), Vec3(16, 16, 3), rock, in: caves)
            part("CaveFrontEast", Vec3(13, 8, -71), Vec3(16, 16, 3), rock, in: caves)
            part("CaveLintel", Vec3(0, 12.5, -71), Vec3(10, 7, 3), rock, in: caves)
            part("CaveRoof", Vec3(0, 16.5, -95), Vec3(48, 2, 52), dark, in: caves)
            // Boulders outside, stalactites within.
            for (x, z, s) in [(Float(-24), Float(-68), Float(6)), (22, -66, 5), (-9, -64, 3.5), (27, -80, 7)] {
                part("Boulder", Vec3(x, s * 0.35, z), Vec3(s, s * 0.8, s), rock, shape: .sphere, in: caves)
            }
            for index in 0..<10 {
                let x = random(-16, 16), z = random(-114, -78), length = random(2, 5)
                part("Stalactite", Vec3(x, 15.5 - length / 2, z), Vec3(1, length, 1), rock, shape: .wedge,
                     rotation: Vec3(180, random(0, 360), 0), in: caves)
                _ = index
            }
            // Crystals, which run the Crystal shader.
            let tints = [rgb(90, 220, 255), rgb(190, 110, 255), rgb(255, 120, 200), rgb(120, 255, 220)]
            for index in 0..<16 {
                let x = random(-17, 17), z = random(-116, -80)
                if abs(x) < 4 && z > -100 { continue }   // keep the way in clear
                let height = random(3, 8)
                part("Crystal", Vec3(x, height / 2 - 0.3, z), Vec3(random(1.2, 2.2), height, random(1.2, 2.2)),
                     tints[index % tints.count], material: .neon,
                     rotation: Vec3(random(-18, 18), random(0, 360), random(-18, 18)), in: caves, shader: crystal)
            }
            part("CaveLightBlue", Vec3(-8, 10, -100), Vec3(0.6, 0.6, 0.6), rgb(90, 200, 255), shape: .sphere,
                 material: .neon, in: caves, light: light(rgb(90, 200, 255), brightness: 2.5, range: 28))
            part("CaveLightPurple", Vec3(9, 10, -86), Vec3(0.6, 0.6, 0.6), rgb(200, 110, 255), shape: .sphere,
                 material: .neon, in: caves, light: light(rgb(200, 110, 255), brightness: 2.5, range: 28))
        }

        mutating func dreamGarden() {
            let garden = group("DreamGarden")
            part("DreamLawn", Vec3(-80, 0.25, 90), Vec3(54, 0.3, 54), rgb(236, 190, 230), shape: .cylinder,
                 material: .smooth, in: garden)
            // Mushrooms to hop up, higher each time, then islands floating above.
            let caps: [(Vec3, Float)] = [(Vec3(-72, 0, 80), 2.5), (Vec3(-80, 0, 88), 5.5), (Vec3(-88, 0, 96), 8.5)]
            for (index, cap) in caps.enumerated() {
                part("Stem\(index + 1)", cap.0 + Vec3(0, cap.1 / 2, 0), Vec3(1.6, cap.1, 1.6), rgb(250, 245, 235),
                     shape: .cylinder, in: garden)
                part("Cap\(index + 1)", cap.0 + Vec3(0, cap.1 + 0.4, 0), Vec3(7, 1.6, 7), rgb(255, 160, 200),
                     shape: .cylinder, in: garden, shader: rainbow)
            }
            for (index, at) in [Vec3(-94, 12, 102), Vec3(-86, 15.5, 110), Vec3(-76, 19, 104)].enumerated() {
                part("Float\(index + 1)", at, Vec3(8, 1.6, 8), rgb(130, 220, 140), material: .smooth, in: garden)
                part("FloatRoots\(index + 1)", at - Vec3(0, 1.6, 0), Vec3(6, 1.6, 6), rgb(150, 110, 90), shape: .sphere,
                     in: garden, collide: false)
            }
            for (x, z, h) in [(Float(-100), Float(76), Float(9)), (-60, 104, 7), (-66, 72, 6), (-100, 110, 8)] {
                part("DreamStem", Vec3(x, h / 2, z), Vec3(2, h, 2), rgb(250, 245, 235), shape: .cylinder, in: garden)
                part("DreamCap", Vec3(x, h + 1.2, z), Vec3(9, 3.6, 9), rgb(170, 140, 255), shape: .sphere, in: garden,
                     shader: rainbow)
            }
            for index in 0..<8 {
                let angle = Float(index) / 8 * 2 * .pi
                part("Firefly", Vec3(-80 + cos(angle) * 18, 3 + Float(index % 3), 90 + sin(angle) * 18),
                     Vec3(0.4, 0.4, 0.4), rgb(255, 250, 170), shape: .sphere, material: .neon, in: garden, collide: false)
            }
        }

        mutating func lake() {
            let lake = group("Lake")
            let rock = rgb(128, 124, 118)
            part("LakeWater", Vec3(82, 2, 92), Vec3(46, 4, 46), rgb(70, 150, 200), material: .water, in: lake,
                 transparency: 0.25, shader: ripple)
            // The banks stand a little above the water, so it sits in a basin.
            part("RimNorth", Vec3(82, 2.3, 68), Vec3(50, 4.6, 2), rock, in: lake)
            part("RimSouth", Vec3(82, 2.3, 116), Vec3(50, 4.6, 2), rock, in: lake)
            part("RimEast", Vec3(106, 2.3, 92), Vec3(2, 4.6, 46), rock, in: lake)
            part("RimWestNorth", Vec3(58, 2.3, 79), Vec3(2, 4.6, 20), rock, in: lake)
            part("RimWestSouth", Vec3(58, 2.3, 105), Vec3(2, 4.6, 20), rock, in: lake)
            // The pier, from the west shore.
            part("Pier", Vec3(64, 4.25, 92), Vec3(16, 0.5, 4), rgb(140, 100, 64), material: .wood, in: lake)
            for x in [Float(58), 64, 70] {
                for z in [Float(90.4), 93.6] {
                    part("PierPost", Vec3(x, 2, z), Vec3(0.5, 4, 0.5), rgb(110, 80, 50), material: .wood, in: lake)
                }
            }
            part("PierSteps", Vec3(54.5, 2, 92), Vec3(4, 4, 5), rgb(140, 100, 64), shape: .wedge, material: .wood,
                 rotation: Vec3(0, -90, 0), in: lake)
            part("Islet", Vec3(94, 2.5, 102), Vec3(9, 5, 9), rgb(210, 190, 140), shape: .cylinder, in: lake)
            part("PalmTrunk", Vec3(96, 8, 103), Vec3(0.8, 7, 0.8), rgb(140, 100, 64), shape: .cylinder,
                 rotation: Vec3(0, 0, 8), in: lake)
            part("PalmLeaves", Vec3(96.6, 11.6, 103), Vec3(6, 1.2, 6), rgb(60, 160, 70), shape: .sphere, in: lake)
            part("Buoy", Vec3(76, 4.3, 82), Vec3(1.2, 1.2, 1.2), rgb(255, 80, 60), shape: .sphere, in: lake, collide: false)
        }

        mutating func lighthouse() {
            let lighthouse = group("Lighthouse")
            let grass = rgb(100, 160, 80)
            for (index, radius) in [Float(40), 30, 20].enumerated() {
                part("Hill\(index + 1)", Vec3(95, 1.5 + Float(index) * 3, -95), Vec3(radius, 3, radius), grass,
                     shape: .cylinder, material: .smooth, in: lighthouse)
            }
            part("Tower", Vec3(95, 23, -95), Vec3(8, 28, 8), rgb(245, 245, 240), shape: .cylinder, in: lighthouse)
            for y in [Float(15), 25, 34] {
                part("Stripe", Vec3(95, y, -95), Vec3(8.3, 2, 8.3), rgb(210, 50, 50), shape: .cylinder, in: lighthouse)
            }
            part("Gallery", Vec3(95, 37.5, -95), Vec3(12, 1, 12), rgb(70, 70, 78), shape: .cylinder, material: .metal,
                 in: lighthouse)
            part("Ladder", Vec3(95, 23.5, -88), Vec3(2, 29, 2), rgb(90, 90, 100), shape: .truss, material: .metal,
                 in: lighthouse)
            part("LampRoom", Vec3(95, 40, -95), Vec3(5, 4, 5), rgb(200, 230, 255), shape: .cylinder, in: lighthouse,
                 transparency: 0.6)
            part("Beacon", Vec3(95, 40, -95), Vec3(2.4, 2.4, 2.4), rgb(255, 240, 180), shape: .sphere, material: .neon,
                 in: lighthouse, collide: false, light: light(rgb(255, 235, 170), brightness: 3, range: 40))
            part("Beam", Vec3(95, 40, -95), Vec3(1.2, 0.8, 44), rgb(255, 245, 190), material: .neon, in: lighthouse,
                 collide: false, transparency: 0.55)
            part("LanternRoof", Vec3(95, 42.6, -95), Vec3(6, 1.2, 6), rgb(210, 50, 50), shape: .cylinder, in: lighthouse)
        }

        mutating func tree(at position: Vec3, height: Float, in parent: UUID) {
            let tree = group("Tree", in: parent)
            part("Trunk", position + Vec3(0, height / 2, 0), Vec3(1.2, height, 1.2), rgb(110, 76, 50), shape: .cylinder,
                 material: .wood, in: tree)
            let leaf = random(0, 1) > 0.5 ? rgb(60, 140, 60) : rgb(80, 160, 70)
            part("Leaves", position + Vec3(0, height + 1.5, 0), Vec3(7, 6, 7), leaf, shape: .sphere, in: tree)
            part("LeavesTop", position + Vec3(0.6, height + 4, -0.4), Vec3(4.5, 4, 4.5), leaf * 1.1, shape: .sphere,
                 in: tree)
        }

        mutating func woods() {
            let woods = group("Woods", kind: .folder)
            // The Whispering Woods, north-west, and trees dotted everywhere else.
            var placed = 0
            while placed < 18 {
                let x = random(-150, -45), z = random(-150, -40)
                tree(at: Vec3(x, 0, z), height: random(5, 8), in: woods)
                placed += 1
            }
            let clearings: [(Vec3, Float)] = [(Vec3(0, 0, 10), 24), (Vec3(0, 0, 78), 32), (Vec3(-88, 0, 10), 50),
                                              (Vec3(-92, 0, -6), 20), (Vec3(85, 0, 10), 30), (Vec3(0, 0, -95), 34),
                                              (Vec3(-80, 0, 90), 34), (Vec3(82, 0, 92), 32), (Vec3(95, 0, -95), 26),
                                              (Vec3(0, 0, -40), 8), (Vec3(-45, 0, 10), 8)]
            var scattered = 0
            while scattered < 22 {
                let x = random(-160, 160), z = random(-150, 150)
                let spot = Vec3(x, 0, z)
                if clearings.contains(where: { simd_distance($0.0, spot) < $0.1 }) { continue }
                tree(at: spot, height: random(5, 8), in: woods)
                scattered += 1
            }
            for _ in 0..<14 {
                let x = random(-170, 170), z = random(-160, 160)
                let spot = Vec3(x, 0, z)
                if clearings.contains(where: { simd_distance($0.0, spot) < $0.1 }) { continue }
                let size = random(2, 5)
                part("Rock", Vec3(x, size * 0.3, z), Vec3(size, size * 0.7, size * 1.2), rgb(140, 136, 130), shape: .sphere,
                     rotation: Vec3(0, random(0, 360), 0), in: woods)
            }
        }

        /// A classic blocky NPC: legs, torso, arms, head with a face, and a hat of parts.
        mutating func npc(_ name: String, at feet: Vec3, shirt: Vec3, pants: Vec3, skin: Vec3 = rgb(245, 205, 60),
                          hat: Vec3? = nil, in folder: UUID) {
            let model = group(name, in: folder)
            part("Left Leg", feet + Vec3(-0.5, 1, 0), Vec3(1, 2, 1), pants, in: model)
            part("Right Leg", feet + Vec3(0.5, 1, 0), Vec3(1, 2, 1), pants, in: model)
            let torso = part("Torso", feet + Vec3(0, 3, 0), Vec3(2, 2, 1), shirt, in: model)
            part("Left Arm", feet + Vec3(-1.5, 3, 0), Vec3(1, 2, 1), skin, in: model)
            part("Right Arm", feet + Vec3(1.5, 3, 0), Vec3(1, 2, 1), skin, in: model)
            part("Head", feet + Vec3(0, 4.65, 0), Vec3(1.3, 1.25, 1.3), skin, shape: .cylinder, in: model)
            let ink = rgb(25, 25, 30)
            for x in [Float(-0.22), 0.22] {
                part("Eye", feet + Vec3(x, 4.8, -0.64), Vec3(0.16, 0.26, 0.06), ink, shape: .sphere, in: model,
                     collide: false)
            }
            part("Smile", feet + Vec3(0, 4.42, -0.64), Vec3(0.44, 0.08, 0.06), ink, in: model, collide: false)
            if let hat {
                part("HatBrim", feet + Vec3(0, 5.3, 0), Vec3(2, 0.12, 2), hat, shape: .cylinder, in: model, collide: false)
                part("HatTop", feet + Vec3(0, 5.8, 0), Vec3(1.3, 1, 1.3), hat, shape: .cylinder, in: model, collide: false)
            }
            if let index = state.groups.firstIndex(where: { $0.id == model }) { state.groups[index].primaryPartID = torso }
        }

        mutating func npcs() {
            let folder = group("NPCs", kind: .folder)
            npc("Guide Pip", at: Vec3(-6, 0.4, 14), shirt: rgb(60, 140, 230), pants: rgb(40, 50, 80),
                hat: rgb(230, 190, 60), in: folder)
            npc("Baker Bo", at: Vec3(0, 0.2, 97), shirt: rgb(250, 250, 245), pants: rgb(90, 70, 60),
                skin: rgb(200, 140, 100), hat: rgb(250, 250, 250), in: folder)
            npc("Old Mara", at: Vec3(-9, 0.3, 86), shirt: rgb(120, 80, 160), pants: rgb(70, 50, 90),
                skin: rgb(230, 190, 150), in: folder)
            npc("Coach Kip", at: Vec3(-42, 0.2, 18), shirt: rgb(230, 70, 60), pants: rgb(40, 40, 50),
                hat: rgb(230, 70, 60), in: folder)
            npc("Professor Lumen", at: Vec3(70, 0.4, 16), shirt: rgb(240, 240, 250), pants: rgb(60, 60, 70),
                skin: rgb(170, 120, 90), in: folder)
            npc("Miner Moe", at: Vec3(7, 0.4, -80), shirt: rgb(200, 140, 60), pants: rgb(60, 70, 90),
                hat: rgb(250, 200, 40), in: folder)
            npc("Dreamer Luna", at: Vec3(-68, 0.4, 72), shirt: rgb(190, 150, 255), pants: rgb(120, 100, 200),
                skin: rgb(250, 220, 200), in: folder)
            npc("Fisher Finn", at: Vec3(69, 4.5, 92), shirt: rgb(70, 130, 90), pants: rgb(60, 60, 80),
                skin: rgb(220, 170, 120), hat: rgb(230, 210, 120), in: folder)
        }

        mutating func gems() {
            let folder = group("Gems", kind: .folder)
            let spots = [Vec3(0, 2, -112), Vec3(-76, 21.5, 104), Vec3(94, 7, 102), Vec3(98, 39.8, -95),
                         Vec3(100, 2.2, 24)]
            let names = ["CaveGem", "DreamGem", "LakeGem", "LighthouseGem", "LabGem"]
            for (spot, name) in zip(spots, names) {
                part(name, spot, Vec3(1.4, 1.4, 1.4), rgb(120, 240, 255), material: .neon, rotation: Vec3(0, 0, 45),
                     in: folder, collide: false, shader: crystal,
                     light: light(rgb(120, 240, 255), brightness: 1.5, range: 10))
            }
        }

        mutating func signs() {
            let signs = group("Signs", kind: .folder)
            sign("Signpost", at: Vec3(7, 0.4, 20), text: """
                North: Crystal Caves   ·   North-east: Lighthouse
                West: Obby Tower   ·   East: Mirror Lab
                South: Village   ·   South-west: Dream Garden   ·   South-east: Lake
                """, signs: signs)
            sign("ObbySign", at: Vec3(-45, 1, 17), text: "OBBY TOWER\nDon't touch the lava or the red bar!", signs: signs)
            sign("LabSignpost", at: Vec3(60, 0, 18), text: "MIRROR LAB\nPull the lever inside to switch on ray tracing",
                 signs: signs)
            sign("CaveSign", at: Vec3(9, 0, -66), text: "CRYSTAL CAVES\nMind your eyes: they glow", signs: signs)
            sign("GardenSign", at: Vec3(-62, 0.3, 70), text: "DREAM GARDEN\nHop the mushrooms up to the floating isles",
                 signs: signs)
            sign("LakeSign", at: Vec3(54, 0, 84), text: "THE LAKE\nSwim to the island (Space swims up)", signs: signs)
            sign("LighthouseSign", at: Vec3(78, 0, -76), text: "LIGHTHOUSE\nClimb the ladder: walk into it", signs: signs)
        }

        /// A chime for finding things: a short bell, made here, kept in the place.
        mutating func chime() {
            let rate = 22050, length = Int(Double(rate) * 0.8)
            var samples: [Int16] = []
            samples.reserveCapacity(length)
            for index in 0..<length {
                let t = Double(index) / Double(rate)
                let bell = sin(2 * .pi * 1318.5 * t) * 0.6 + sin(2 * .pi * 1975.5 * t) * 0.3 + sin(2 * .pi * 2637 * t) * 0.15
                let envelope = min(t * 200, 1) * exp(-t * 5)
                samples.append(Int16(max(-1, min(1, bell * envelope * 0.6)) * 32000))
            }
            var wav = Data("RIFF".utf8)
            func field(_ value: Int, _ size: Int) {
                wav.append(contentsOf: withUnsafeBytes(of: UInt32(value).littleEndian, Array.init).prefix(size))
            }
            field(36 + samples.count * 2, 4)
            wav.append(contentsOf: Array("WAVEfmt ".utf8))
            for (value, size) in [(16, 4), (1, 2), (1, 2), (rate, 4), (rate * 2, 4), (2, 2), (16, 2)] { field(value, size) }
            wav.append(contentsOf: Array("data".utf8))
            field(samples.count * 2, 4)
            for sample in samples { wav.append(contentsOf: withUnsafeBytes(of: sample.littleEndian, Array.init)) }
            state.assets.append(SceneAsset(name: "Chime", kind: .sound, data: wav, fileExtension: "wav"))
            var sound = SceneSound(name: "Chime", parentID: nil)
            sound.soundId = "studio://Chime"
            sound.volume = 0.6
            state.sounds.append(sound)
        }

        mutating func data() {
            state.dataObjects += [
                DataObject(name: "Notify", className: .remoteEvent, parent: .replicatedStorage),
                DataObject(name: "Quest", className: .remoteFunction, parent: .replicatedStorage),
                // Server scripts telling each other about rewards: only the server needs it.
                DataObject(name: "Reward", className: .bindableEvent, parent: .serverStorage),
            ]
        }

        mutating func scripts() {
            typealias S = AdventureIslandScripts
            script("Dialogue", S.dialogue, host: .replicatedStorage, module: true)
            script("Zones", S.zones, host: .replicatedStorage, module: true)
            script("GameScript", S.game)
            script("Ambience", S.ambience)
            if let obby = state.groups.first(where: { $0.name == "Obby" }) { script("ObbyScript", S.obby, in: obby.id) }
            if let lab = state.groups.first(where: { $0.name == "MirrorLab" }) { script("LabScript", S.lab, in: lab.id) }
            if let npcs = state.groups.first(where: { $0.name == "NPCs" }) { script("NPCBrain", S.npcBrain, in: npcs.id) }
            script("Adventure", S.adventure, host: .starterPlayer)
        }

        /// The default HUD and leaderboard, less the Studio keys (no flying up the Obby
        /// Tower), its controls list telling of E and Tab instead.
        mutating func hud() {
            var made = DefaultHud.make(keys: false)
            for index in made.objects.indices {
                switch made.objects[index].name {
                case "Line7": made.objects[index].properties["text"] = .string("E          talk")
                case "Line8": made.objects[index].properties["text"] = .string("Tab        leaderboard")
                default: break
                }
            }
            state.starterGui = made.objects
            state.scripts += made.scripts
        }
    }
}

extension SceneModel {
    /// Opens Adventure Island, as a new unsaved scene.
    func loadAdventureIsland() {
        commit("Opened \(AdventureIsland.name)") {
            state = AdventureIsland.state()
            selection = []
            selectedScript = nil
            selectedShader = nil
        }
        clearHistory()
        noteChange()
        statusText = "Loaded \(AdventureIsland.name)"
    }
}
