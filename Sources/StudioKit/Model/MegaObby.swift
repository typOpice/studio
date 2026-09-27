import Foundation
import simd

/// Mega Obby: sixty stages in six worlds of ten — Grassy Meadows, Lava Caves, Frozen
/// Peaks, Candy Land, Neon City and Sky Kingdom — each harder than the last. Every stage
/// ends at a numbered Checkpoint you come back to; the Finish after the sixtieth is a Win.
///
/// The course is built from a dozen kinds of obstacle, each sized by how far along the
/// course it is. What they do is decided by their names, in the Mechanics script
/// (MegaObbyScripts.swift): KillBrick, KillFloor, KillMover, Mover, Spinner, FadeTile,
/// JumpPad. ObbyGame keeps each player's stage, and the ObbyScreen LocalScript shows it,
/// with a stage picker.
enum MegaObby {
    static let name = "Mega Obby"
    static let stages = 60

    static func state() -> SceneState {
        var builder = Builder()
        builder.build()
        builder.state.placeID = placeID
        return builder.state
    }

    /// The same place wherever it's opened, so what it saves (each player's stage) is kept.
    static let placeID = UUID(uuidString: "0B1B0B1B-0060-4060-8060-000000000060")!

    static func rgb(_ r: Float, _ g: Float, _ b: Float) -> Vec3 { Vec3(r, g, b) / 255 }

    struct World {
        var name: String
        var platform: Vec3
        var accent: Vec3
        var kill: Vec3
        var floor: Vec3
        var floorShader: String?
    }

    static let worlds: [World] = [
        World(name: "Grassy Meadows", platform: rgb(116, 190, 96), accent: rgb(170, 128, 84), kill: rgb(235, 60, 50),
              floor: rgb(70, 130, 70)),
        World(name: "Lava Caves", platform: rgb(92, 84, 80), accent: rgb(140, 110, 96), kill: rgb(255, 110, 30),
              floor: rgb(255, 90, 20), floorShader: "Lava"),
        World(name: "Frozen Peaks", platform: rgb(214, 236, 255), accent: rgb(130, 180, 230), kill: rgb(230, 60, 110),
              floor: rgb(50, 110, 190)),
        World(name: "Candy Land", platform: rgb(255, 176, 214), accent: rgb(170, 220, 255), kill: rgb(240, 50, 120),
              floor: rgb(255, 224, 240)),
        World(name: "Neon City", platform: rgb(44, 48, 66), accent: rgb(0, 230, 255), kill: rgb(255, 40, 200),
              floor: rgb(18, 18, 28), floorShader: "Grid"),
        World(name: "Sky Kingdom", platform: rgb(248, 248, 255), accent: rgb(255, 210, 90), kill: rgb(240, 70, 70),
              floor: rgb(255, 255, 255), floorShader: "Clouds"),
    ]

    /// What each stage is, world by world: a mix, so no two stages in a row are alike.
    enum Obstacle: String, CaseIterable {
        case jumps, zigzag, beam, fadeTiles, pillars, walls, truss, spinner, movers, sweepers, lavaPillars, ledges,
             jumpPad, dropdown
    }

    static let plan: [[Obstacle]] = [
        [.jumps, .zigzag, .beam, .fadeTiles, .pillars, .walls, .truss, .jumps, .spinner, .movers],
        [.lavaPillars, .jumps, .walls, .sweepers, .spinner, .ledges, .movers, .fadeTiles, .beam, .jumpPad],
        [.zigzag, .fadeTiles, .beam, .truss, .pillars, .sweepers, .jumps, .spinner, .movers, .ledges],
        [.jumpPad, .walls, .spinner, .zigzag, .movers, .lavaPillars, .fadeTiles, .sweepers, .beam, .jumps],
        [.sweepers, .movers, .spinner, .fadeTiles, .ledges, .zigzag, .walls, .pillars, .jumpPad, .beam],
        [.spinner, .sweepers, .movers, .fadeTiles, .pillars, .truss, .zigzag, .walls, .jumps, .beam],
    ]

    // MARK: - Building

    struct Builder: PlaceBuilding {
        var state = SceneState()
        var seed: UInt32 = 60_606_060
        private var shaders: [String: UUID] = [:]
        /// Where the next checkpoint's top is, and the stage building now.
        private var cursor = Vec3(0, 20, 6)
        private var stage = 1
        private var world = MegaObby.worlds[0]
        private var into = UUID()
        private var checkpoints = UUID()

        mutating func build() {
            var lighting = LightingSettings()
            lighting.clockTime = 14
            lighting.fogStart = 250
            lighting.fogEnd = 700
            var clouds = CloudSettings()
            clouds.cover = 0.35
            lighting.clouds = clouds
            state.lighting = lighting
            state.starterPlayer.respawnTime = 1
            shaders["Lava"] = shader("Lava", .surface, AdventureIslandScripts.lavaShader, [("speed", 1.2)])
            shaders["Grid"] = shader("Grid", .surface, MegaObbyScripts.gridShader, [("speed", 1)])
            shaders["Clouds"] = shader("Clouds", .surface, MegaObbyScripts.cloudShader, [("speed", 0.4)])
            checkpoints = group("Checkpoints", kind: .folder)
            lobby()
            let course = group("Course", kind: .folder)
            for (index, worldPlan) in MegaObby.plan.enumerated() {
                world = MegaObby.worlds[index]
                let worldStart = cursor.z
                into = group("World\(index + 1)", kind: .model, in: course)
                for obstacle in worldPlan {
                    var kind = obstacle
                    // Keep the course within sight of the ground: nothing climbs above 50.
                    if cursor.y > 46, [.truss, .jumpPad, .ledges].contains(kind) { kind = .dropdown }
                    let stageGroup = group("Stage\(stage)", in: into)
                    let edge = build(kind, in: stageGroup)
                    stage += 1
                    // The next checkpoint starts at the edge the obstacle ends at; the
                    // last is followed by the finish.
                    let half: Float = stage > MegaObby.stages ? 12 : (stage - 1) % 10 == 0 ? 7 : 4
                    cursor = Vec3(edge.x, edge.y, edge.z - half)
                    if stage <= MegaObby.stages { checkpoint(stage, at: cursor) }
                }
                // Ground under each world: fall and you're out. Worlds meet without overlapping.
                let end = stage > MegaObby.stages ? cursor.z - 50 : cursor.z
                part("KillFloor", Vec3(0, -0.3, (worldStart + end) / 2), Vec3(400, 1, worldStart - end), world.floor,
                     material: world.floorShader == nil ? .plastic : .neon, in: into,
                     shader: world.floorShader.flatMap { shaders[$0] })
            }
            finish()
            data()
            // The music, from the start, for everyone.
            sound("Music", "builtin://ObbyRun", volume: 0.3, looped: true, playing: true)
            scripts()
            hud()
            state.defaultGui = DefaultHud.version
        }

        // MARK: Pieces

        private var t: Float { Float(stage - 1) / Float(MegaObby.stages - 1) }

        private func mix(_ easy: Float, _ hard: Float) -> Float { easy + (hard - easy) * t }

        /// A block with its top at `top`, centred on x and z.
        @discardableResult
        private mutating func slab(_ name: String, top: Vec3, _ size: Vec3, _ colour: Vec3, shape: PartShape = .block,
                                   material: PartMaterial = .plastic, collide: Bool = true, in parent: UUID) -> UUID {
            part(name, top - Vec3(0, size.y / 2, 0), size, colour, shape: shape, material: material, in: parent,
                 collide: collide)
        }

        /// A Trail off each end of a spinning bar: a fading sweep behind its tips.
        private mutating func sweep(_ bar: UUID, length: Float, colour: Vec3) {
            var look = RibbonLook()
            look.color = .from(colour, to: colour)
            look.transparency = .from(0.15, to: 1)
            look.lightEmission = 0.2
            look.lifetime = 0.5
            look.minLength = 0.3
            for end: Float in [1, -1] {
                let outer = attachment(on: bar, at: Vec3(end * length / 2, 0, 0), name: "TipOuter")
                let inner = attachment(on: bar, at: Vec3(end * (length / 2 - 2.5), 0, 0), name: "TipInner")
                ribbon(.trail, outer, inner, in: bar, name: "Sweep", look)
            }
        }

        private mutating func number(_ name: String, _ value: Double, in part: UUID) {
            var object = DataObject(name: name, className: .numberValue, parent: .node(part))
            object.number = value
            state.dataObjects.append(object)
        }

        private mutating func moves(_ part: UUID, by offset: Vec3, seconds: Float) {
            var object = DataObject(name: "Offset", className: .vector3Value, parent: .node(part))
            object.numbers = [Double(offset.x), Double(offset.y), Double(offset.z)]
            state.dataObjects.append(object)
            number("Seconds", Double(seconds), in: part)
        }

        private mutating func checkpoint(_ number: Int, at top: Vec3) {
            let startsWorld = (number - 1) % 10 == 0
            // The world it's in by its number: a world's first comes at the end of the last.
            let world = MegaObby.worlds[min((number - 1) / 10, MegaObby.worlds.count - 1)]
            let size = startsWorld ? Vec3(14, 1, 14) : Vec3(8, 1, 8)
            let pad = slab("Checkpoint", top: top, size, number == 1 ? MegaObby.rgb(90, 200, 255) : world.accent,
                           in: checkpoints)
            var value = DataObject(name: "Stage", className: .intValue, parent: .node(pad))
            value.number = Double(number)
            state.dataObjects.append(value)
            if startsWorld {
                var name = DataObject(name: "World", className: .stringValue, parent: .node(pad))
                name.text = "World \((number - 1) / 10 + 1): \(world.name)"
                state.dataObjects.append(name)
            }
        }

        private mutating func lobby() {
            let lobby = group("Lobby")
            let top: Float = 20
            slab("Floor", top: Vec3(0, top, 18), Vec3(36, 1, 36), MegaObby.rgb(200, 206, 214), in: lobby)
            slab("SpawnPad", top: Vec3(0, top + 0.3, 18), Vec3(6, 0.3, 6), MegaObby.rgb(80, 160, 240), material: .neon,
                 in: lobby)
            for x in [Float(-6), 6] {
                part("ArchPost", Vec3(x, top + 4, 1), Vec3(1.2, 8, 1.2), MegaObby.rgb(255, 200, 60), in: lobby)
            }
            part("ArchTop", Vec3(0, top + 8.6, 1), Vec3(13.2, 1.2, 1.2), MegaObby.rgb(255, 200, 60), in: lobby)
            part("ArchSign", Vec3(0, top + 10.2, 1), Vec3(10, 2, 0.4), MegaObby.rgb(240, 60, 60), material: .neon,
                 in: lobby)
            for (x, z) in [(Float(-14), Float(30)), (14, 30), (-14, 8), (14, 8)] {
                part("Planter", Vec3(x, top + 0.8, z), Vec3(3, 1.6, 3), MegaObby.rgb(150, 100, 60), in: lobby)
                part("Bush", Vec3(x, top + 2.6, z), Vec3(3.2, 2.6, 3.2), MegaObby.rgb(80, 170, 80), shape: .sphere,
                     in: lobby, collide: false)
            }
            // The first checkpoint is here, at the start line.
            checkpoint(1, at: Vec3(0, top + 0.05, 6))
            part("KillFloor", Vec3(0, -0.3, 43), Vec3(400, 1, 74), MegaObby.worlds[0].floor, in: lobby)
        }

        // MARK: Obstacles, each from the checkpoint at `cursor` to the near edge of the next

        /// Sized for a character that jumps about 6.4 studs up and, running, about 8
        /// across: no gap is wider than that allows at its height.
        mutating func build(_ kind: Obstacle, in parent: UUID) -> Vec3 {
            let x = cursor.x
            var y = cursor.y
            // The far edge of the checkpoint (a world's first is bigger).
            var z = cursor.z - ((stage - 1) % 10 == 0 ? 7 : 4)
            switch kind {
            case .jumps, .dropdown:
                let size = mix(5, 2.8)
                let gap = mix(3, 5.2)
                let count = kind == .dropdown ? 4 : 4 + Int(t * 2.5)
                for _ in 0..<count {
                    y += kind == .dropdown ? -3 : random(y > 40 ? -1.5 : 0, 1.2)
                    z -= gap + size / 2
                    slab("Jump", top: Vec3(x + random(-1, 1) * (0.5 + 1.5 * t), y, z), Vec3(size, 1, size),
                         world.platform, in: parent)
                    z -= size / 2
                }
                return Vec3(x, y, z - gap)

            case .zigzag:
                let size = mix(4.6, 3)
                var side: Float = 1
                for _ in 0..<(5 + Int(t * 2)) {
                    z -= mix(4.5, 6)
                    y += random(0, 0.8)
                    slab("Zig", top: Vec3(x + side * mix(2, 3.5), y, z), Vec3(size, 1, size), world.platform, in: parent)
                    side = -side
                }
                return Vec3(x, y, z - size / 2 - mix(2.5, 4))

            case .beam:
                let width = mix(3, 1.1)
                let length = mix(14, 26)
                slab("Beam", top: Vec3(x, y, z - length / 2), Vec3(width, 1, length), world.accent, in: parent)
                // Later, bumps to hop over along the way.
                if t > 0.3 {
                    for i in 1...2 {
                        slab("KillBrick", top: Vec3(x, y + 1, z - length * Float(i) / 3), Vec3(width, 1, 0.8), world.kill,
                             material: .neon, in: parent)
                    }
                }
                return Vec3(x, y, z - length)

            case .fadeTiles:
                let gap = mix(1.5, 3)
                for _ in 0..<(6 + Int(t * 3)) {
                    z -= gap + 2
                    slab("FadeTile", top: Vec3(x + random(-1, 1) * 2 * t, y, z), Vec3(4, 1, 4), world.accent, in: parent)
                    z -= 2
                }
                return Vec3(x, y, z - gap)

            case .pillars, .lavaPillars:
                let width = mix(3.6, 2.2)
                let gap = mix(2.5, 4.4)
                let count = 5 + Int(t * 2)
                let start = z
                for i in 0..<count {
                    z -= gap + width / 2
                    let rise = kind == .pillars ? Float(i) * 0.8 : random(-0.5, 0.8)
                    let height = 6 + rise
                    part("Pillar", Vec3(x + random(-1, 1) * 1.5 * t, y + rise - height / 2, z), Vec3(width, height, width),
                         world.platform, shape: .cylinder, in: parent)
                    z -= width / 2
                }
                y += kind == .pillars ? Float(count - 1) * 0.8 : 0
                if kind == .lavaPillars {
                    // Lava below: close enough to see what you'd fall into.
                    slab("KillBrick", top: Vec3(x, cursor.y - 5, (start + z) / 2), Vec3(14, 0.8, start - z + 4), world.kill,
                         material: .neon, in: parent)
                }
                return Vec3(x, y, z - gap)

            case .walls:
                let length = mix(22, 34)
                slab("Walkway", top: Vec3(x, y, z - length / 2), Vec3(10, 1, length), world.platform, in: parent)
                var at = z - 5
                var side: Float = 1
                while at > z - length + 3 {
                    if t > 0.45 && side < 0 {
                        // A low wall to jump over.
                        slab("KillBrick", top: Vec3(x, y + 1.3, at), Vec3(10, 1.3, 0.8), world.kill, material: .neon, in: parent)
                    } else {
                        // A wall with a gap to get through.
                        let gap = mix(3.4, 2.4)
                        let gapAt = x + side * 2.5
                        let left = (x - 5, gapAt - gap / 2), right = (gapAt + gap / 2, x + 5)
                        for (from, to) in [left, right] where to - from > 0.1 {
                            slab("KillBrick", top: Vec3((from + to) / 2, y + 5, at), Vec3(to - from, 5, 0.8), world.kill,
                                 material: .neon, in: parent)
                        }
                    }
                    side = -side
                    at -= mix(6, 4.5)
                }
                return Vec3(x, y, z - length)

            case .truss:
                let height = mix(8, 14)
                slab("Walkway", top: Vec3(x, y, z - 3), Vec3(5, 1, 6), world.platform, in: parent)
                part("Truss", Vec3(x, y + height / 2, z - 7), Vec3(2, height, 2), world.accent, shape: .truss, in: parent)
                slab("Ledge", top: Vec3(x, y + height, z - 11), Vec3(6, 1, 6), world.platform, in: parent)
                y += height
                return Vec3(x, y, z - 14 - mix(2.5, 4))

            case .spinner:
                let disc = mix(14, 17)
                let centre = z - 2 - disc / 2
                slab("Disc", top: Vec3(x, y, centre), Vec3(disc, 1, disc), world.platform, shape: .cylinder, in: parent)
                let bar = part("Spinner", Vec3(x, y + 1.4, centre), Vec3(disc - 1, 0.8, 0.8), world.kill,
                               material: .neon, in: parent, collide: false)
                number("Speed", Double(mix(70, 160)), in: bar)
                sweep(bar, length: disc - 1, colour: world.kill)
                if t > 0.5 {
                    let cross = part("Spinner", Vec3(x, y + 1.4, centre), Vec3(disc - 1, 0.8, 0.8), world.kill,
                                     material: .neon, rotation: Vec3(0, 90, 0), in: parent, collide: false)
                    number("Speed", Double(mix(70, 160)), in: cross)
                    sweep(cross, length: disc - 1, colour: world.kill)
                }
                part("Hub", Vec3(x, y + 1.4, centre), Vec3(1.4, 2.4, 1.4), world.accent, shape: .cylinder, in: parent)
                return Vec3(x, y, centre - disc / 2 - 2)

            case .movers:
                let seconds = mix(3, 1.7)
                let reach = mix(7, 11)
                var side: Float = 1
                for _ in 0..<(2 + Int(t * 2)) {
                    z -= 3 + 2.5
                    let mover = slab("Mover", top: Vec3(x - side * reach / 2, y, z), Vec3(5, 1, 5), world.accent, in: parent)
                    moves(mover, by: Vec3(side * reach, 0, 0), seconds: seconds)
                    z -= 2.5
                    side = -side
                }
                return Vec3(x, y, z - 3)

            case .sweepers:
                let length = mix(24, 34)
                slab("Walkway", top: Vec3(x, y, z - length / 2), Vec3(10, 1, length), world.platform, in: parent)
                var at = z - 6
                var side: Float = 1
                while at > z - length + 4 {
                    let sweeper = slab("KillMover", top: Vec3(x - side * 4, y + 3, at), Vec3(2, 3, 2), world.kill,
                                       material: .neon, in: parent)
                    moves(sweeper, by: Vec3(side * 8, 0, 0), seconds: mix(2, 1.1))
                    side = -side
                    at -= mix(7, 5.5)
                }
                return Vec3(x, y, z - length)

            case .ledges:
                let count = 4 + Int(t * 2)
                for i in 0..<count {
                    z -= mix(2, 3) + 1.25
                    y += 2.4
                    slab("Ledge", top: Vec3(x + (i % 2 == 0 ? -1.5 : 1.5), y, z), Vec3(2.5, 1, 2.5), world.accent, in: parent)
                    z -= 1.25
                }
                return Vec3(x, y, z - mix(2, 3))

            case .jumpPad:
                slab("Launch", top: Vec3(x, y, z - 4), Vec3(8, 1, 8), world.platform, in: parent)
                let pad = slab("JumpPad", top: Vec3(x, y + 0.4, z - 5), Vec3(4, 0.4, 4), MegaObby.rgb(80, 220, 255),
                               material: .neon, in: parent)
                // Power 95 goes about 23 studs up: in the air long enough to cross the gap and land 8 up.
                number("Power", 95, in: pad)
                let gap = mix(6, 9)
                y += 8
                slab("Landing", top: Vec3(x, y, z - 8 - gap - 5), Vec3(10, 1, 10), world.platform, in: parent)
                return Vec3(x, y, z - 18 - gap - 1)
            }
        }

        mutating func finish() {
            let end = group("Finish Line")
            let gold = MegaObby.rgb(255, 205, 70)
            slab("Victory", top: cursor, Vec3(24, 1, 24), MegaObby.rgb(250, 250, 255), in: end)
            slab("Finish", top: cursor + Vec3(0, 0.3, -4), Vec3(10, 0.3, 6), gold, material: .neon, in: end)
            let trophy = part("Trophy", cursor + Vec3(0, 3.4, -9), Vec3(2.4, 2.4, 2.4), gold, shape: .sphere,
                              material: .neon, in: end, collide: false, light: light(gold, brightness: 2.5, range: 24))
            // Thrown up when someone wins (ObbyScript's Emit).
            emit([ParticleEmitter.preset(.confetti)], from: trophy)
            part("TrophyBase", cursor + Vec3(0, 1.2, -9), Vec3(2, 2, 2), MegaObby.rgb(120, 110, 100), in: end)
            for x in [Float(-10), 10] {
                part("Tower", cursor + Vec3(x, 6, -10), Vec3(4, 12, 4), MegaObby.rgb(236, 236, 244), in: end)
                part("FlagPole", cursor + Vec3(x, 13.8, -10), Vec3(0.25, 3.6, 0.25), MegaObby.rgb(90, 90, 96), in: end,
                     collide: false)
                part("Flag", cursor + Vec3(x + 1.3, 14.8, -10), Vec3(2.4, 1.4, 0.15), MegaObby.rgb(240, 60, 60), in: end,
                     collide: false)
            }
        }

        // MARK: Data, scripts and the screen

        mutating func data() {
            for name in ["Notify", "GoToStage"] {
                state.dataObjects.append(DataObject(name: name, className: .remoteEvent, parent: .replicatedStorage))
            }
            var stages = DataObject(name: "Stages", className: .intValue, parent: .replicatedStorage)
            stages.number = Double(MegaObby.stages)
            state.dataObjects.append(stages)
        }

        mutating func scripts() {
            state.scripts.append(UtilsModule.make())
            script("ObbyGame", MegaObbyScripts.game)
            script("Mechanics", MegaObbyScripts.mechanics)
            script("ObbyScreen", MegaObbyScripts.screen, host: .starterPlayer)
        }

        mutating func hud() {
            var made = DefaultHud.make(keys: false)
            // The F and R lines (fly, respawn) aren't this game's keys.
            DefaultHud.relabel(&made.objects, key: "F", to: "Q E        stage back, on")
            DefaultHud.relabel(&made.objects, key: "R", to: "R          back to checkpoint")
            state.starterGui = made.objects
            state.scripts += made.scripts
        }
    }
}

extension SceneModel {
    /// Opens Mega Obby, as a new unsaved scene.
    func loadMegaObby() {
        loadTemplate(.megaObby)
    }
}
