import Foundation
import simd

/// Nightfall: a roguelike made only of what Studio offers. A walled valley to explore by
/// day — a camp, an abandoned town with an armory, a graveyard, a forest, a farm, a mine
/// and some ruins — and zombies by night, more and tougher each night. Fight with the
/// sword you start with and the blaster in the armory; zombies drop orbs, and each dawn
/// and each level brings a choice of three power-ups. Three keys are hidden in new places
/// every run: find them and the north gate opens to escape. Fall, or escape, and the run
/// is over: a new one starts from nothing.
///
/// The rules are Luau (NightfallScripts.swift): GameScript runs the days and nights, the
/// Horde module moves and fights the zombies, Upgrades holds the power-ups, and the
/// Nightfall LocalScript is each player's screen.
enum Nightfall {
    static let name = "Nightfall"

    /// The whole place, ready to open or save.
    static func state() -> SceneState {
        var builder = Builder()
        builder.build()
        // Tools and ServerStorage park their parts; the model knows how.
        let model = SceneModel()
        model.state = builder.state
        model.setToolPlace(builder.sword, .starterPack)
        for id in builder.stored { model.setStorage(id, .serverStorage) }
        model.placeID = placeID
        return model.state
    }

    /// The same place wherever it's opened, so what it saves (the best run) is kept.
    static let placeID = UUID(uuidString: "0B16B7FA-0000-4A11-8000-000013131313")!

    static func rgb(_ r: Float, _ g: Float, _ b: Float) -> Vec3 { Vec3(r, g, b) / 255 }

    /// The ground's top: a little above y 0, where the grid and the physics ground are.
    static let groundTop: Float = 0.2

    // MARK: - Building

    struct Builder: PlaceBuilding {
        var state = SceneState()
        var seed: UInt32 = 13_131_313
        /// Kept in ServerStorage once built: the zombies, the key and the blaster.
        var stored: [UUID] = []
        var sword = UUID()
        private var fire = UUID()
        private var keyGlow = UUID()

        mutating func build() {
            state.lighting = lighting()
            state.starterPlayer.respawnTime = 3
            shaders()
            ground()
            boundary()
            camp()
            town()
            graveyard()
            forest()
            farm()
            mine()
            ruins()
            markers()
            templates()
            tools()
            data()
            sounds()
            scripts()
            hud()
            state.defaultGui = DefaultHud.version
        }

        /// Heard everywhere: the day's music (playing from the start) and the night's, and
        /// what GameScript sounds for everyone. The rest are made where they happen.
        mutating func sounds() {
            sound("DayMusic", "builtin://CalmDay", volume: 0.35, looped: true, playing: true)
            sound("NightMusic", "builtin://NightHunt", volume: 0.4, looped: true)
            sound("NightFalls", "builtin://Gong", volume: 0.9)
            sound("Dawn", "builtin://Chime", volume: 0.8)
            sound("KeyFound", "builtin://Sparkle", volume: 0.8)
            sound("GateOpens", "builtin://Rumble", volume: 1)
        }

        func lighting() -> LightingSettings {
            var lighting = LightingSettings()
            // Late afternoon; GameScript turns it to night and back.
            lighting.clockTime = 16.5
            lighting.brightness = 2
            lighting.fogColor = rgb(120, 130, 150)
            lighting.fogStart = 120
            lighting.fogEnd = 380
            return lighting
        }

        mutating func shaders() {
            fire = shader("Fire", .surface, NightfallScripts.fireShader, [("speed", 1)])
            keyGlow = shader("KeyGlow", .surface, NightfallScripts.keyGlowShader, [("speed", 1)])
            _ = shader("Hurt", .screen, NightfallScripts.hurtShader, [("amount", 1)])
            _ = shader("Night", .screen, NightfallScripts.nightShader, [("amount", 1)])
        }

        // MARK: Land

        mutating func ground() {
            part("Ground", Vec3(0, -0.8, 0), Vec3(470, 2, 470), rgb(58, 74, 44), material: .plastic)
            let roads = group("Roads", kind: .folder)
            let dirt = rgb(110, 92, 66)
            func road(_ name: String, from a: Vec3, to b: Vec3, width: Float = 7) {
                let middle = (a + b) / 2
                let length = simd_length(b - a)
                let heading = atan2(b.x - a.x, b.z - a.z) * 180 / .pi
                part(name, Vec3(middle.x, 0.25, middle.z), Vec3(width, 0.1, length), dirt, material: .plastic,
                     rotation: Vec3(0, heading, 0), in: roads)
            }
            road("ToGate", from: Vec3(0, 0, 20), to: Vec3(0, 0, 188))
            road("ToTown", from: Vec3(8, 0, 18), to: Vec3(80, 0, 84))
            road("ToGraveyard", from: Vec3(-8, 0, 18), to: Vec3(-86, 0, 88))
            road("ToForest", from: Vec3(-8, 0, -2), to: Vec3(-86, 0, -76))
            road("ToFarm", from: Vec3(8, 0, -2), to: Vec3(76, 0, -64))
            road("ToMine", from: Vec3(16, 0, 5), to: Vec3(158, 0, 5))
            road("ToRuins", from: Vec3(-16, 0, 5), to: Vec3(-146, 0, 5))
        }

        /// A palisade round the valley, and the north gate in it.
        mutating func boundary() {
            let walls = group("Walls")
            let wood = rgb(70, 52, 38)
            part("SouthWall", Vec3(0, 6, -190), Vec3(382, 12, 2), wood, material: .wood, in: walls)
            part("EastWall", Vec3(190, 6, 0), Vec3(2, 12, 382), wood, material: .wood, in: walls)
            part("WestWall", Vec3(-190, 6, 0), Vec3(2, 12, 382), wood, material: .wood, in: walls)
            part("NorthWallWest", Vec3(-101, 6, 190), Vec3(178, 12, 2), wood, material: .wood, in: walls)
            part("NorthWallEast", Vec3(101, 6, 190), Vec3(178, 12, 2), wood, material: .wood, in: walls)

            let gate = group("Gate")
            let stone = rgb(96, 96, 104)
            for x in [Float(-14), 14] {
                part("Tower", Vec3(x, 9, 190), Vec3(6, 18, 6), stone, material: .smooth, in: gate)
                part("Torch", Vec3(x, 12, 186.6), Vec3(0.8, 1.6, 0.8), rgb(255, 150, 60), material: .neon,
                     in: gate, collide: false, shader: fire, light: light(rgb(255, 150, 70), brightness: 2, range: 22))
            }
            part("Arch", Vec3(0, 16.5, 190), Vec3(22, 3, 6), stone, material: .smooth, in: gate)
            let iron = rgb(52, 52, 58)
            part("DoorLeft", Vec3(-4.5, 7.6, 190), Vec3(9, 14.8, 1.2), iron, material: .metal, in: gate)
            part("DoorRight", Vec3(4.5, 7.6, 190), Vec3(9, 14.8, 1.2), iron, material: .metal, in: gate)
            part("GateLight", Vec3(0, 16.5, 186.8), Vec3(1.4, 1.4, 1.4), rgb(230, 60, 50), shape: .sphere,
                 material: .neon, in: gate, collide: false, light: light(rgb(230, 60, 50), brightness: 3, range: 30))
            // Beyond the gate: step on it with the gate open and you've escaped.
            part("EscapeZone", Vec3(0, 0.35, 206), Vec3(18, 0.3, 12), rgb(90, 240, 140), material: .neon,
                 in: gate, collide: false, transparency: 0.35)
        }

        // MARK: Places

        mutating func camp() {
            let camp = group("Camp")
            part("CampGround", Vec3(0, 0.26, 8), Vec3(36, 0.12, 36), rgb(104, 86, 62), shape: .cylinder,
                 material: .plastic, in: camp)
            part("SpawnPad", Vec3(0, 0.35, 18), Vec3(6, 0.3, 6), rgb(80, 160, 240), material: .neon, in: camp)
            let stone = rgb(110, 110, 115)
            for i in 0..<8 {
                let angle = Float(i) * .pi / 4
                part("FireStone", Vec3(2.4 * sin(angle), 0.55, 8 + 2.4 * cos(angle)), Vec3(0.9, 0.7, 0.9), stone,
                     material: .smooth, in: camp)
            }
            let wood = rgb(92, 62, 40)
            part("Log", Vec3(0, 0.7, 8), Vec3(0.8, 3.6, 0.8), wood, shape: .cylinder, material: .wood,
                 rotation: Vec3(90, 45, 0), in: camp)
            part("Log", Vec3(0, 0.7, 8), Vec3(0.8, 3.6, 0.8), wood, shape: .cylinder, material: .wood,
                 rotation: Vec3(90, -45, 0), in: camp)
            part("Flames", Vec3(0, 1.8, 8), Vec3(1.9, 2.8, 1.9), rgb(255, 140, 40), shape: .sphere, material: .neon,
                 in: camp, collide: false, shader: fire,
                 light: light(rgb(255, 160, 80), brightness: 3, range: 36, shadows: true))
            part("Flame", Vec3(0.3, 2.9, 8.2), Vec3(0.9, 1.6, 0.9), rgb(255, 200, 80), shape: .sphere, material: .neon,
                 in: camp, collide: false, shader: fire)
            for (x, z, colour) in [(Float(-13), Float(6), rgb(70, 110, 70)), (13, 6, rgb(170, 110, 50)),
                                   (-9, -6, rgb(80, 90, 140))] {
                tent(at: Vec3(x, 0, z), colour: colour, in: camp)
            }
            for (x, z) in [(Float(-17), Float(-2)), (-16, -4.5), (17, -3)] {
                part("Crate", Vec3(x, 1.2, z), Vec3(2, 2, 2), rgb(140, 104, 64), material: .wood, in: camp)
            }
            part("LanternPost", Vec3(9, 2.2, 16), Vec3(0.4, 4, 0.4), wood, material: .wood, in: camp)
            part("Lantern", Vec3(9, 4.5, 16), Vec3(0.8, 0.8, 0.8), rgb(255, 214, 140), material: .neon, in: camp,
                 collide: false, light: light(rgb(255, 214, 140), brightness: 1.5, range: 18))
        }

        mutating func tent(at base: Vec3, colour: Vec3, in parent: UUID) {
            part("Tent", base + Vec3(-1.1, 1.6, 0), Vec3(0.2, 3.6, 5), colour, material: .plastic,
                 rotation: Vec3(0, 0, -35), in: parent)
            part("Tent", base + Vec3(1.1, 1.6, 0), Vec3(0.2, 3.6, 5), colour, material: .plastic,
                 rotation: Vec3(0, 0, 35), in: parent)
        }

        mutating func house(_ name: String, at centre: Vec3, colour: Vec3, roof: Vec3, in parent: UUID) {
            let house = group(name, in: parent)
            let base = centre + Vec3(0, Nightfall.groundTop, 0)
            part("Walls", base + Vec3(0, 3.5, 0), Vec3(12, 7, 10), colour, material: .wood, in: house)
            part("RoofNorth", base + Vec3(0, 8.5, -2.5), Vec3(12.6, 3, 5.4), roof, shape: .wedge,
                 rotation: Vec3(0, 180, 0), in: house)
            part("RoofSouth", base + Vec3(0, 8.5, 2.5), Vec3(12.6, 3, 5.4), roof, shape: .wedge, in: house)
            // Boarded up: dark doors and windows, a plank across each.
            let dark = rgb(34, 30, 28), plank = rgb(120, 88, 58)
            part("Door", base + Vec3(0, 2, 5.05), Vec3(2.4, 4, 0.2), dark, in: house)
            for x in [Float(-3.6), 3.6] {
                part("Window", base + Vec3(x, 4.2, 5.05), Vec3(1.8, 1.6, 0.2), dark, in: house)
                part("Plank", base + Vec3(x, 4.2, 5.2), Vec3(2.2, 0.35, 0.15), plank, material: .wood,
                     rotation: Vec3(0, 0, 20), in: house)
            }
        }

        mutating func town() {
            let town = group("Town")
            part("Square", Vec3(95, 0.26, 100), Vec3(40, 0.12, 40), rgb(96, 92, 88), material: .smooth, in: town)
            let colours = [rgb(150, 120, 96), rgb(120, 110, 100), rgb(160, 140, 110), rgb(110, 96, 90), rgb(130, 100, 90)]
            let roofs = [rgb(90, 50, 44), rgb(60, 60, 70), rgb(80, 70, 50), rgb(70, 44, 40), rgb(56, 64, 56)]
            for (index, spot) in [Vec3(68, 0, 122), Vec3(122, 0, 122), Vec3(68, 0, 80), Vec3(124, 0, 78),
                                  Vec3(146, 0, 102)].enumerated() {
                house("House\(index + 1)", at: spot, colour: colours[index], roof: roofs[index], in: town)
            }

            // The church, its door to the square.
            let church = group("Church", in: town)
            let stone = rgb(130, 128, 124)
            part("Nave", Vec3(95, 5.2, 134), Vec3(12, 10, 18), stone, material: .smooth, in: church)
            // A wedge's high side is its −Z: turned a quarter each way, they meet along the nave.
            part("RoofWest", Vec3(92.2, 12.2, 134), Vec3(19, 4, 5.6), rgb(60, 56, 60), shape: .wedge,
                 rotation: Vec3(0, -90, 0), in: church)
            part("RoofEast", Vec3(97.8, 12.2, 134), Vec3(19, 4, 5.6), rgb(60, 56, 60), shape: .wedge,
                 rotation: Vec3(0, 90, 0), in: church)
            part("Steeple", Vec3(95, 9, 124), Vec3(4, 18, 4), stone, material: .smooth, in: church)
            part("Spire", Vec3(95, 19.6, 124), Vec3(3, 3.2, 3), rgb(60, 56, 60), shape: .wedge, in: church)
            part("CrossUp", Vec3(95, 23, 124), Vec3(0.4, 2.4, 0.4), rgb(40, 40, 44), in: church)
            part("CrossBar", Vec3(95, 23.4, 124), Vec3(1.4, 0.4, 0.4), rgb(40, 40, 44), in: church)
            part("ChurchDoor", Vec3(95, 2.4, 121.9), Vec3(3, 4.4, 0.2), rgb(70, 46, 30), material: .wood, in: church)

            // The armory, open to the square, the blaster on a pedestal inside.
            let armory = group("Armory", in: town)
            let brick = rgb(120, 70, 60)
            part("BackWall", Vec3(95, 4.2, 63.5), Vec3(14, 8, 1), brick, material: .plastic, in: armory)
            part("SideWall", Vec3(88.5, 4.2, 69), Vec3(1, 8, 10), brick, material: .plastic, in: armory)
            part("SideWall", Vec3(101.5, 4.2, 69), Vec3(1, 8, 10), brick, material: .plastic, in: armory)
            part("Roof", Vec3(95, 8.7, 69), Vec3(16, 1, 12), rgb(60, 50, 46), in: armory)
            part("Floor", Vec3(95, 0.3, 69), Vec3(12, 0.2, 10), rgb(80, 74, 70), material: .smooth, in: armory)
            part("Pedestal", Vec3(95, 1.45, 66), Vec3(2, 2.5, 2), rgb(90, 90, 96), material: .smooth, in: armory)
            let display = group("BlasterDisplay", in: armory)
            part("Body", Vec3(95, 3.3, 66), Vec3(0.6, 0.8, 2.2), rgb(60, 64, 72), material: .metal, in: display,
                 collide: false)
            part("Barrel", Vec3(95, 3.4, 64.4), Vec3(0.3, 0.3, 1.2), rgb(150, 156, 166), material: .metal, in: display,
                 collide: false)
            part("Glow", Vec3(95, 3.4, 63.8), Vec3(0.34, 0.34, 0.2), rgb(80, 220, 255), material: .neon, in: display,
                 collide: false, light: light(rgb(80, 220, 255), brightness: 1.5, range: 10))
            part("BlasterPickup", Vec3(95, 2.2, 67.5), Vec3(4, 4, 4), rgb(80, 220, 255), in: armory, collide: false,
                 transparency: 1)

            // The water tower: climb its ladder for the view (and sometimes a key).
            let tower = group("WaterTower", in: town)
            let metal = rgb(110, 100, 90)
            for (x, z) in [(Float(-3), Float(-3)), (3, -3), (-3, 3), (3, 3)] {
                part("Leg", Vec3(140 + x, 8.2, 130 + z), Vec3(0.8, 16, 0.8), metal, shape: .cylinder, material: .metal,
                     in: tower)
            }
            part("Tank", Vec3(140, 19.2, 130), Vec3(8, 6, 8), rgb(130, 110, 90), shape: .cylinder, material: .wood,
                 in: tower)
            part("Ladder", Vec3(140, 11.2, 134.6), Vec3(2, 22, 2), metal, shape: .truss, in: tower)

            part("Well", Vec3(95, 1.4, 100), Vec3(4, 2.4, 4), rgb(110, 110, 116), shape: .cylinder, material: .smooth,
                 in: town)
            part("WellWater", Vec3(95, 2.5, 100), Vec3(3.2, 0.2, 3.2), rgb(30, 50, 70), shape: .cylinder, in: town,
                 collide: false)
            for (x, z) in [(Float(78), Float(92)), (112, 92), (78, 108), (112, 108)] {
                part("LampPost", Vec3(x, 3.2, z), Vec3(0.4, 6, 0.4), rgb(40, 40, 44), in: town)
                part("Lamp", Vec3(x, 6.5, z), Vec3(0.9, 0.9, 0.9), rgb(255, 200, 120), shape: .sphere, material: .neon,
                     in: town, collide: false, light: light(rgb(255, 200, 120), brightness: 1.2, range: 20))
            }
        }

        mutating func graveyard() {
            let yard = group("Graveyard")
            part("Soil", Vec3(-100, 0.26, 110), Vec3(52, 0.12, 46), rgb(52, 58, 44), material: .plastic, in: yard)
            // An iron fence, with a way in from the south.
            let iron = rgb(30, 30, 34)
            var x: Float = -126
            while x <= -74 {
                for z in [Float(87), 133] where !(z == 87 && abs(x + 100) < 4) {
                    part("FencePost", Vec3(x, 1.7, z), Vec3(0.4, 3, 0.4), iron, in: yard)
                }
                x += 4
            }
            var z: Float = 91
            while z <= 129 {
                for x in [Float(-126), -74] { part("FencePost", Vec3(x, 1.7, z), Vec3(0.4, 3, 0.4), iron, in: yard) }
                z += 4
            }
            // The rails are rusted through: anyone (or anything) can squeeze between the posts.
            for y in [Float(1.2), 2.6] {
                part("Rail", Vec3(-100, y, 133), Vec3(52, 0.25, 0.25), iron, in: yard, collide: false)
                part("Rail", Vec3(-114.5, y, 87), Vec3(23, 0.25, 0.25), iron, in: yard, collide: false)
                part("Rail", Vec3(-85.5, y, 87), Vec3(23, 0.25, 0.25), iron, in: yard, collide: false)
                part("Rail", Vec3(-126, y, 110), Vec3(0.25, 0.25, 46), iron, in: yard, collide: false)
                part("Rail", Vec3(-74, y, 110), Vec3(0.25, 0.25, 46), iron, in: yard, collide: false)
            }
            let grey = rgb(120, 120, 126), mound = rgb(76, 62, 48)
            for row in 0..<4 {
                for column in 0..<5 {
                    let spot = Vec3(-115 + Float(column) * 7.5, 0, 96 + Float(row) * 7)
                    part("Gravestone", spot + Vec3(0, 1.45, 0), Vec3(2, 2.5, 0.5), grey, material: .smooth,
                         rotation: Vec3(random(-6, 6), 0, random(-8, 8)), in: yard)
                    part("Mound", spot + Vec3(0, 0.35, 2.2), Vec3(1.8, 0.3, 3.4), mound, material: .plastic, in: yard,
                         collide: false)
                }
            }
            // The crypt: step inside.
            let crypt = group("Crypt", in: yard)
            let stone = rgb(100, 100, 108)
            part("BackWall", Vec3(-100, 3.7, 131), Vec3(10, 7, 0.8), stone, material: .smooth, in: crypt)
            part("SideWall", Vec3(-105, 3.7, 127), Vec3(0.8, 7, 8), stone, material: .smooth, in: crypt)
            part("SideWall", Vec3(-95, 3.7, 127), Vec3(0.8, 7, 8), stone, material: .smooth, in: crypt)
            part("FrontLeft", Vec3(-103.25, 3.7, 123), Vec3(3.5, 7, 0.8), stone, material: .smooth, in: crypt)
            part("FrontRight", Vec3(-96.75, 3.7, 123), Vec3(3.5, 7, 0.8), stone, material: .smooth, in: crypt)
            part("Lintel", Vec3(-100, 6.45, 123), Vec3(3, 1.5, 0.8), stone, material: .smooth, in: crypt)
            part("Roof", Vec3(-100, 7.6, 127), Vec3(11, 0.8, 9), rgb(70, 70, 78), material: .smooth, in: crypt)
            part("Candle", Vec3(-100, 1, 130), Vec3(0.3, 1, 0.3), rgb(190, 140, 255), material: .neon, in: crypt,
                 collide: false, light: light(rgb(170, 120, 255), brightness: 2, range: 14))
            // Dead trees and a few will-o'-the-wisps.
            for spot in [Vec3(-120, 0, 92), Vec3(-80, 0, 128), Vec3(-78, 0, 95)] {
                let trunk = rgb(50, 42, 36)
                part("DeadTree", spot + Vec3(0, 3.7, 0), Vec3(0.9, 7, 0.9), trunk, shape: .cylinder, material: .wood,
                     in: yard)
                part("Branch", spot + Vec3(0.9, 5.6, 0), Vec3(0.4, 3, 0.4), trunk, shape: .cylinder, material: .wood,
                     rotation: Vec3(0, 0, -45), in: yard, collide: false)
                part("Branch", spot + Vec3(-0.8, 6.4, 0.3), Vec3(0.35, 2.4, 0.35), trunk, shape: .cylinder,
                     material: .wood, rotation: Vec3(20, 0, 50), in: yard, collide: false)
            }
            for spot in [Vec3(-110, 3, 104), Vec3(-88, 2.5, 118)] {
                part("Wisp", spot, Vec3(0.6, 0.6, 0.6), rgb(170, 120, 255), shape: .sphere, material: .neon, in: yard,
                     collide: false, light: light(rgb(150, 110, 255), brightness: 1.5, range: 16))
            }
        }

        mutating func tree(at spot: Vec3, in parent: UUID) {
            let tree = group("Tree", in: parent)
            let height = random(5, 8)
            part("Trunk", spot + Vec3(0, Nightfall.groundTop + height / 2, 0), Vec3(1, height, 1), rgb(70, 50, 36),
                 shape: .cylinder, material: .wood, in: tree)
            let green = rgb(34 + random(0, 14), 70 + random(0, 20), 40)
            part("Leaves", spot + Vec3(0, height + 0.5, 0), Vec3(5.5, 4.5, 5.5), green, shape: .sphere,
                 material: .plastic, in: tree, collide: false)
            part("LeavesTop", spot + Vec3(0, height + 3, 0), Vec3(3.6, 3.4, 3.6), green, shape: .sphere,
                 material: .plastic, in: tree, collide: false)
        }

        mutating func forest() {
            let forest = group("Forest")
            var planted = 0
            var tries = 0
            while planted < 46 && tries < 600 {
                tries += 1
                let x = random(-178, -34), z = random(-178, -34)
                // Clear of the cabin, the watchtower, the road and each other.
                if simd_distance(SIMD2<Float>(x, z), SIMD2<Float>(-95, -84)) < 13 || simd_distance(SIMD2<Float>(x, z), SIMD2<Float>(-122, -122)) < 8
                    || abs(x - z) < 9 { continue }
                tree(at: Vec3(x, 0, z), in: forest)
                planted += 1
            }
            let cabin = group("Cabin", in: forest)
            let log = rgb(110, 76, 48)
            part("Walls", Vec3(-95, 3.2, -88), Vec3(10, 6, 8), log, material: .wood, in: cabin)
            part("RoofNorth", Vec3(-95, 7.7, -90), Vec3(10.6, 3, 4.4), rgb(70, 48, 36), shape: .wedge,
                 rotation: Vec3(0, 180, 0), in: cabin)
            part("RoofSouth", Vec3(-95, 7.7, -86), Vec3(10.6, 3, 4.4), rgb(70, 48, 36), shape: .wedge, in: cabin)
            part("Porch", Vec3(-95, 0.5, -82.5), Vec3(10, 0.6, 3), rgb(130, 96, 60), material: .wood, in: cabin)
            part("Door", Vec3(-95, 2.3, -83.95), Vec3(2.2, 3.8, 0.2), rgb(60, 40, 28), in: cabin)

            let tower = group("Watchtower", in: forest)
            let wood = rgb(100, 72, 46)
            for (x, z) in [(Float(-2.5), Float(-2.5)), (2.5, -2.5), (-2.5, 2.5), (2.5, 2.5)] {
                part("Leg", Vec3(-122 + x, 7.2, -122 + z), Vec3(0.8, 14, 0.8), wood, material: .wood, in: tower)
            }
            part("Platform", Vec3(-122, 14.5, -122), Vec3(7, 0.6, 7), wood, material: .wood, in: tower)
            for (x, z, w, d) in [(Float(0), Float(-3.4), Float(7), Float(0.3)), (-3.4, 0, 0.3, 7), (3.4, 0, 0.3, 7)] {
                part("Railing", Vec3(-122 + x, 15.6, -122 + z), Vec3(w, 1.6, d), wood, material: .wood, in: tower)
            }
            part("Ladder", Vec3(-122, 7.6, -117.6), Vec3(2, 14.8, 2), rgb(90, 90, 96), shape: .truss, in: tower)
        }

        mutating func farm() {
            let farm = group("Farm")
            let soil = rgb(92, 66, 44), crop = rgb(90, 140, 60)
            for row in 0..<7 {
                let z = -128 + Float(row) * 4
                part("Field", Vec3(80, 0.27, z), Vec3(30, 0.14, 2.6), soil, material: .plastic, in: farm)
                if row % 2 == 0 {
                    part("Crops", Vec3(80, 0.75, z), Vec3(29, 0.8, 0.8), crop, material: .plastic, in: farm, collide: false)
                }
            }
            let barn = group("Barn", in: farm)
            part("Walls", Vec3(118, 4.7, -92), Vec3(14, 9, 18), rgb(150, 44, 40), material: .wood, in: barn)
            part("RoofWest", Vec3(114.5, 11, -92), Vec3(19, 3.6, 7.2), rgb(60, 50, 50), shape: .wedge,
                 rotation: Vec3(0, -90, 0), in: barn)
            part("RoofEast", Vec3(121.5, 11, -92), Vec3(19, 3.6, 7.2), rgb(60, 50, 50), shape: .wedge,
                 rotation: Vec3(0, 90, 0), in: barn)
            part("BarnDoor", Vec3(110.95, 3.7, -92), Vec3(0.2, 7, 7), rgb(235, 225, 210), in: barn)
            // Hay: a pile to climb.
            let hay = rgb(214, 180, 90)
            for (x, y, z) in [(Float(102), Float(1.2), Float(-78)), (104.2, 1.2, -78), (106.4, 1.2, -78),
                              (103.1, 3.2, -78), (105.3, 3.2, -78)] {
                part("HayBale", Vec3(x, y, z), Vec3(2, 3, 2), hay, shape: .cylinder, material: .plastic,
                     rotation: Vec3(90, 0, 0), in: farm)
            }
            part("Silo", Vec3(134, 9.2, -108), Vec3(7, 18, 7), rgb(160, 160, 166), shape: .cylinder, material: .metal,
                 in: farm)
            part("SiloTop", Vec3(134, 18.2, -108), Vec3(7, 4, 7), rgb(130, 130, 136), shape: .sphere, material: .metal,
                 in: farm)
            // The windmill: Ambience turns the sails.
            let mill = group("Windmill", in: farm)
            part("Tower", Vec3(84, 6.2, -74), Vec3(4, 12, 4), rgb(200, 190, 170), material: .wood, in: mill)
            part("Hub", Vec3(84, 11, -71.6), Vec3(1, 1, 1), rgb(80, 60, 40), shape: .cylinder, material: .wood,
                 rotation: Vec3(90, 0, 0), in: mill)
            let sails = group("Sails", in: mill)
            for (index, angle) in [Float(0), 90, 180, 270].enumerated() {
                let radians = angle * .pi / 180
                part("Sail\(index + 1)", Vec3(84 + 3.4 * sin(radians), 11 + 3.4 * cos(radians), -71.2),
                     Vec3(1.2, 6, 0.2), rgb(236, 230, 214), material: .plastic, rotation: Vec3(0, 0, -angle),
                     in: sails, collide: false)
            }
            let post = rgb(110, 80, 50)
            part("Scarecrow", Vec3(70, 2.6, -110), Vec3(0.4, 4.8, 0.4), post, material: .wood, in: farm)
            part("ScarecrowArms", Vec3(70, 3.8, -110), Vec3(3.4, 0.35, 0.35), post, material: .wood, in: farm)
            part("ScarecrowHead", Vec3(70, 5.3, -110), Vec3(1.1, 1.1, 1.1), hay, shape: .sphere, material: .plastic,
                 in: farm)
        }

        mutating func mine() {
            let mine = group("Mine")
            let rock = rgb(92, 88, 84)
            for (x, z, w, h, d, turn) in [(Float(172), Float(-14), Float(24), Float(12), Float(22), Float(12)),
                                          (176, 24, 22, 14, 22, -8), (184, 5, 10, 16, 14, 0),
                                          (160, 34, 14, 8, 12, 25), (162, -28, 16, 9, 14, -20)] {
                part("Rock", Vec3(x, h / 2 + 0.2, z), Vec3(w, h, d), rock, material: .smooth, rotation: Vec3(0, turn, 0),
                     in: mine)
            }
            part("TunnelFloor", Vec3(169, 0.35, 5), Vec3(20, 0.3, 6), rgb(70, 62, 56), material: .smooth, in: mine)
            part("TunnelWall", Vec3(169, 3.7, 1.5), Vec3(20, 7, 1), rock, material: .smooth, in: mine)
            part("TunnelWall", Vec3(169, 3.7, 8.5), Vec3(20, 7, 1), rock, material: .smooth, in: mine)
            part("TunnelRoof", Vec3(169, 7.6, 5), Vec3(20, 1, 8), rock, material: .smooth, in: mine)
            let beam = rgb(110, 80, 50)
            for z in [Float(2.2), 7.8] {
                part("Post", Vec3(159, 3.45, z), Vec3(0.8, 6.5, 0.8), beam, material: .wood, in: mine)
            }
            part("Beam", Vec3(159, 6.6, 5), Vec3(0.8, 0.8, 7), beam, material: .wood, in: mine)
            part("Minecart", Vec3(172, 1.3, 5), Vec3(3.4, 1.5, 2.4), rgb(80, 80, 86), material: .metal, in: mine)
            part("Lantern", Vec3(174, 5.5, 2.2), Vec3(0.7, 0.7, 0.7), rgb(255, 200, 110), material: .neon, in: mine,
                 collide: false, light: light(rgb(255, 200, 110), brightness: 2, range: 16))
        }

        mutating func ruins() {
            let ruins = group("Ruins")
            let stone = rgb(150, 144, 130)
            for (x, z, w, h, d) in [(Float(-172), Float(-8), Float(1.5), Float(4), Float(14)),
                                    (-172, 20, 1.5, 6, 8), (-150, -8, 1.5, 3, 10), (-160, -14, 16, 5, 1.5),
                                    (-155, 26, 12, 2.5, 1.5)] {
                part("BrokenWall", Vec3(x, h / 2 + 0.2, z), Vec3(w, h, d), stone, material: .smooth, in: ruins)
            }
            for (x, z, h) in [(Float(-156), Float(0), Float(7)), (-156, 10, 4.5), (-146, 18, 6)] {
                part("Column", Vec3(x, h / 2 + 0.2, z), Vec3(1.6, h, 1.6), stone, shape: .cylinder, material: .smooth,
                     in: ruins)
            }
            part("FallenColumn", Vec3(-150, 1, 6), Vec3(1.6, 7, 1.6), stone, shape: .cylinder, material: .smooth,
                 rotation: Vec3(0, 30, 90), in: ruins)
            // A broken tower, with steps up its side to the top.
            part("Tower", Vec3(-165, 5.2, 12), Vec3(6, 10, 6), stone, material: .smooth, in: ruins)
            for step in 1...8 {
                let height = Float(step) * 1.25
                part("Step", Vec3(-160.8, 0.2 + height / 2, 24 - Float(step - 1) * 1.5), Vec3(2, height, 1.5),
                     stone, material: .smooth, in: ruins)
            }
        }

        // MARK: Markers, templates and tools

        /// Invisible marks the scripts read: where zombies come from, where keys may be.
        mutating func markers() {
            _ = group("Zombies", kind: .folder)
            _ = group("Orbs", kind: .folder)
            _ = group("Keys", kind: .folder)
            let spawns = group("SpawnPoints", kind: .folder)
            let spawnSpots: [(Float, Float)] = [
                (-112, 100), (-88, 116), (-108, 120), (-92, 98), (-140, -60), (-60, -140), (-150, -150),
                (80, -120), (145, -140), (150, -70), (150, 150), (60, 150), (150, 60), (150, 40), (150, -30),
                (-150, 30), (-150, -25), (0, -170), (-170, 170), (170, 170),
            ]
            for (index, spot) in spawnSpots.enumerated() {
                part("Spawn\(index + 1)", Vec3(spot.0, 1, spot.1), Vec3(1, 1, 1), rgb(200, 60, 60), in: spawns,
                     collide: false, transparency: 1)
            }
            let keys = group("KeySpots", kind: .folder)
            let keySpots: [(String, Vec3)] = [
                ("Crypt", Vec3(-100, 1.8, 128)), ("WaterTower", Vec3(140, 23.6, 130)), ("Well", Vec3(99, 1.8, 100)),
                ("Church", Vec3(95, 1.8, 120)), ("Cabin", Vec3(-95, 2, -82.5)), ("Watchtower", Vec3(-122, 16.4, -122)),
                ("HayPile", Vec3(104.2, 5.6, -78)), ("Windmill", Vec3(84, 1.8, -79)), ("Mine", Vec3(176, 1.8, 5)),
                ("RuinedTower", Vec3(-165, 11.6, 12)), ("GraveyardCorner", Vec3(-121, 1.8, 129)),
                ("ForestHollow", Vec3(-150, 1.8, -110)),
            ]
            for (name, spot) in keySpots {
                part(name, spot, Vec3(1, 1, 1), rgb(255, 200, 60), in: keys, collide: false, transparency: 1)
            }
        }

        /// A zombie, facing −Z like every character, its Torso the PrimaryPart. Built far
        /// away and kept in ServerStorage; GameScript clones them.
        mutating func zombie(_ name: String, scale s: Float, skin: Vec3, shirt: Vec3, pants: Vec3) {
            let model = group(name)
            let feet = Vec3(0, Nightfall.groundTop, -320) + Vec3(Float(stored.count) * 8, 0, 0)
            func at(_ x: Float, _ y: Float, _ z: Float) -> Vec3 { feet + Vec3(x, y, z) * s }
            part("Left Leg", at(-0.5, 1, 0), Vec3(1, 2, 1) * s, pants, in: model, collide: false)
            part("Right Leg", at(0.5, 1, 0), Vec3(1, 2, 1) * s, pants, in: model, collide: false)
            let torso = part("Torso", at(0, 3, 0), Vec3(2, 2, 1) * s, shirt, in: model)
            // Arms held out in front, as zombies do.
            part("Left Arm", at(-1.5, 3.5, -0.7), Vec3(1, 1, 2.2) * s, skin, in: model, collide: false)
            part("Right Arm", at(1.5, 3.5, -0.7), Vec3(1, 1, 2.2) * s, skin, in: model, collide: false)
            let head = part("Head", at(0, 4.6, 0), Vec3(1.2, 1.2, 1.2) * s, skin, in: model, collide: false)
            // Horde.step has it groan now and then.
            sound("Groan", "builtin://Groan", in: head, volume: 0.9, reach: 70)
            for x in [Float(-0.25), 0.25] {
                part("Eye", at(x, 4.75, -0.62), Vec3(0.26, 0.16, 0.05) * s, rgb(255, 60, 40), material: .neon,
                     in: model, collide: false)
            }
            if let index = state.groups.firstIndex(where: { $0.id == model }) { state.groups[index].primaryPartID = torso }
            stored.append(model)
        }

        mutating func templates() {
            zombie("Walker", scale: 1, skin: rgb(120, 150, 90), shirt: rgb(70, 90, 130), pants: rgb(80, 64, 50))
            zombie("Runner", scale: 0.9, skin: rgb(170, 180, 150), shirt: rgb(140, 50, 50), pants: rgb(50, 50, 56))
            zombie("Brute", scale: 1.45, skin: rgb(80, 110, 70), shirt: rgb(40, 40, 44), pants: rgb(60, 50, 40))

            // A key: a ring, a shaft and teeth, all gold.
            let key = group("Key")
            let gold = rgb(255, 200, 60)
            let spot = Vec3(40, 2, -320)
            let ring = part("Ring", spot, Vec3(1.6, 0.35, 1.6), gold, shape: .cylinder, material: .neon,
                            rotation: Vec3(90, 0, 0), in: key, collide: false, shader: keyGlow,
                            light: light(gold, brightness: 2, range: 14))
            part("Shaft", spot + Vec3(0, -1.6, 0), Vec3(0.35, 2.2, 0.35), gold, material: .neon, in: key,
                 collide: false, shader: keyGlow)
            part("Tooth", spot + Vec3(0.4, -2.4, 0), Vec3(0.5, 0.3, 0.3), gold, material: .neon, in: key,
                 collide: false, shader: keyGlow)
            part("Tooth", spot + Vec3(0.3, -1.9, 0), Vec3(0.3, 0.3, 0.3), gold, material: .neon, in: key,
                 collide: false, shader: keyGlow)
            if let index = state.groups.firstIndex(where: { $0.id == key }) { state.groups[index].primaryPartID = ring }
            stored.append(key)
        }

        mutating func tools() {
            // The sword everyone starts with.
            sword = group("Sword", kind: .tool)
            let grip = Vec3(0, 3, -330)
            part("Handle", grip, Vec3(0.4, 1.4, 0.4), rgb(90, 60, 40), material: .wood, in: sword)
            part("Guard", grip + Vec3(0, 0.85, 0), Vec3(1.4, 0.3, 0.4), rgb(120, 120, 128), material: .metal, in: sword,
                 collide: false)
            part("Blade", grip + Vec3(0, 3, 0), Vec3(0.3, 4, 0.12), rgb(210, 216, 226), material: .metal, in: sword,
                 collide: false)
            script("SwordScript", NightfallScripts.sword, in: sword)

            // The blaster, found in the armory.
            let blaster = group("Blaster", kind: .tool)
            let hold = Vec3(10, 3, -330)
            part("Handle", hold, Vec3(0.5, 1.2, 0.5), rgb(50, 52, 58), material: .metal, in: blaster)
            part("Body", hold + Vec3(0, 0.9, -0.6), Vec3(0.6, 0.8, 2.2), rgb(60, 64, 72), material: .metal, in: blaster,
                 collide: false)
            part("Barrel", hold + Vec3(0, 1, -2.2), Vec3(0.3, 0.3, 1.2), rgb(150, 156, 166), material: .metal,
                 in: blaster, collide: false)
            part("Glow", hold + Vec3(0, 1, -2.85), Vec3(0.34, 0.34, 0.2), rgb(80, 220, 255), material: .neon,
                 in: blaster, collide: false)
            stored.append(blaster)
        }

        // MARK: Data, scripts and the screen

        mutating func data() {
            func add(_ name: String, _ kind: DataClass, in parent: DataParent) -> UUID {
                let object = DataObject(name: name, className: kind, parent: parent)
                state.dataObjects.append(object)
                return object.id
            }
            for name in ["Notify", "Offer", "Choose", "Fire", "Dash", "RunOver"] {
                _ = add(name, .remoteEvent, in: .replicatedStorage)
            }
            // What every screen shows, set by GameScript.
            let status = add("Status", .folder, in: .replicatedStorage)
            _ = add("Phase", .stringValue, in: .node(status))
            for name in ["Night", "Countdown", "ZombiesLeft", "KeysFound", "KeysNeeded"] {
                _ = add(name, .intValue, in: .node(status))
            }
            _ = add("GateOpen", .boolValue, in: .node(status))
            // Numbers to tune the game by, in ServerStorage.
            let settings = add("Settings", .folder, in: .serverStorage)
            for (name, value) in [("DayLength", 45.0), ("DawnLength", 15), ("FirstNight", 6), ("MorePerNight", 4),
                                  ("MaxZombies", 24), ("KeysNeeded", 3)] {
                var object = DataObject(name: name, className: .numberValue, parent: .node(settings))
                object.number = value
                state.dataObjects.append(object)
            }
        }

        mutating func scripts() {
            state.scripts.append(UtilsModule.make())
            script("Horde", NightfallScripts.horde, host: .serverStorage, module: true)
            script("Upgrades", NightfallScripts.upgrades, host: .serverStorage, module: true)
            script("GameScript", NightfallScripts.game)
            script("Ambience", NightfallScripts.ambience)
            script("Nightfall", NightfallScripts.screen, host: .starterPlayer)
        }

        mutating func hud() {
            var made = DefaultHud.make(keys: false)
            // The F and R lines (fly, respawn) aren't this game's keys.
            DefaultHud.relabel(&made.objects, key: "F", to: "click      swing, shoot")
            DefaultHud.relabel(&made.objects, key: "R", to: "Q          dash (power-up)")
            state.starterGui = made.objects
            state.scripts += made.scripts
        }
    }
}

extension SceneModel {
    /// Opens Nightfall, as a new unsaved scene.
    func loadNightfall() {
        loadTemplate(.nightfall)
    }
}
