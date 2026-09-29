import Foundation
import simd

/// The places the home page starts from: a baseplate to build on, a small obby with
/// its script, the starter scene to learn from, an empty place, and Adventure Island.
/// Each opens as a new, untitled place (`SceneModel.loadTemplate`), and every one but
/// Adventure Island has what a new place has: the default HUD and the Utils module.
enum PlaceTemplate: String, CaseIterable, Identifiable {
    case baseplate, obby, starter, terrain, empty, adventure, nightfall, megaObby, racing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .baseplate: return "Baseplate"
        case .obby: return "Obby"
        case .starter: return "Starter Scene"
        case .terrain: return "Hills and Lake"
        case .empty: return "Empty"
        case .adventure: return AdventureIsland.name
        case .nightfall: return Nightfall.name
        case .racing: return Racing.name
        case .megaObby: return MegaObby.name
        }
    }

    var summary: String {
        switch self {
        case .baseplate: return "A big grey baseplate and a spawn pad, ready to build on."
        case .obby: return "Jumps, kill bricks, checkpoints and a finish, with the script that runs them."
        case .starter: return "A few parts, a script, shaders and an animation to learn from."
        case .terrain: return "Rolling terrain with a river and lakes, to shape with the Terrain Editor."
        case .empty: return "Nothing but the HUD and Utils. Start from scratch."
        case .adventure:
            return "An open world to explore: NPCs to talk to, an obby tower, a ray-traced mirror lab, "
                + "crystal caves and a dream garden with their own shaders, gems to find."
        case .nightfall:
            return "A roguelike: explore a walled valley by day and fight off zombies by night with a sword and a "
                + "blaster. Pick power-ups, find three hidden keys, and escape through the north gate."
        case .racing: return "Four breakable cars, three laps, NPC rivals and multiplayer. Race the countdown, hit the gates and keep your wheels on."
        case .megaObby:
            return "Sixty stages in six worlds, from Grassy Meadows to the Sky Kingdom: jumps, beams, spinners, "
                + "moving platforms, fading tiles and jump pads, a checkpoint on every stage and a stage picker."
        }
    }

    /// A sample game's card lists what's in it.
    var tags: [String] {
        switch self {
        case .adventure: return ["Explore", "8 NPCs", "Obby tower", "Ray tracing", "Shaders", "Multiplayer"]
        case .nightfall: return ["Roguelike", "Zombies", "Sword and blaster", "14 power-ups", "Hidden keys", "Multiplayer"]
        case .racing: return ["Racing", "Breakable cars", "NPC rivals", "3 laps", "Multiplayer"]
        case .megaObby: return ["60 stages", "6 worlds", "Checkpoints", "Stage picker", "Movers and spinners", "Multiplayer"]
        default: return []
        }
    }

    /// For when there's no picture yet.
    var symbol: String {
        switch self {
        case .baseplate: return "square.grid.3x3.fill"
        case .obby: return "figure.run"
        case .starter: return "cube.transparent"
        case .terrain: return "mountain.2.fill"
        case .empty: return "doc"
        case .adventure: return "map.fill"
        case .nightfall: return "moon.stars.fill"
        case .racing: return "car.fill"
        case .megaObby: return "flag.checkered"
        }
    }

    /// The ones listed under New; the sample games have a section of their own.
    static var starters: [PlaceTemplate] { [.baseplate, .obby, .starter, .terrain, .empty] }
    static var samples: [PlaceTemplate] { [.adventure, .nightfall, .megaObby, .racing] }

    /// The place, built fresh.
    func state() -> SceneState {
        switch self {
        case .baseplate: return Self.baseplateState()
        case .obby: return Self.obbyState()
        case .starter: return SceneModel().state
        case .terrain: return Self.terrainState()
        case .empty: return Self.emptyState()
        case .adventure: return AdventureIsland.state()
        case .nightfall: return Nightfall.state()
        case .racing: return Racing.state()
        case .megaObby: return MegaObby.state()
        }
    }

    /// Where its picture is taken from, when framing its parts wouldn't show it well.
    var thumbnailCamera: Camera? {
        var camera = Camera()
        camera.fovDegrees = 50
        switch self {
        case .baseplate:
            camera.target = Vec3(0, 0, 16)
            camera.distance = 30
            camera.pitch = 0.42
        case .obby:
            // From behind the start, down the course.
            camera.target = Vec3(-2, 5, -40)
            camera.distance = 72
            camera.yaw = .pi / 2 - 0.45
            camera.pitch = 0.3
        case .adventure:
            camera.target = Vec3(0, 0, 10)
            camera.distance = 250
            camera.yaw = .pi / 2 + 0.35
            camera.pitch = 0.72
        case .terrain:
            camera.target = Vec3(0, 10, 0)
            camera.distance = 330
            camera.yaw = .pi / 2 + 0.6
            camera.pitch = 0.5
        case .megaObby:
            // From beside the lobby, down the first world's stages.
            camera.target = Vec3(0, 18, -30)
            camera.distance = 70
            camera.yaw = .pi / 2 + 0.55
            camera.pitch = 0.32
        case .racing:
            camera.target = Vec3(94, 5, -2)
            camera.distance = 82
            camera.yaw = .pi / 2 + 0.55
            camera.pitch = 0.48
        case .nightfall:
            // The camp and its fire, the town and graveyard beyond.
            camera.target = Vec3(0, 2, 40)
            camera.distance = 150
            camera.yaw = -.pi / 2 + 0.25
            camera.pitch = 0.42
        default:
            return nil
        }
        return camera
    }

    /// Where a character stands in its picture: on the spawn, for scale.
    var thumbnailCharacter: Vec3? {
        switch self {
        case .baseplate: return Vec3(0, 0.5, 18)
        case .obby: return Vec3(0, 1, 18)
        default: return nil
        }
    }

    // MARK: - Building

    /// What File › New makes: the default HUD and Utils, nothing else.
    private static func emptyState() -> SceneState {
        let model = SceneModel()
        model.clearScene()
        return model.state
    }

    private static func baseplate() -> Part {
        var plate = Part()
        plate.name = "Baseplate"
        // Its top a little above y 0, where the editor's grid and the physics ground
        // are, so they don't fight over the same pixels.
        plate.position = Vec3(0, -0.3, 0)
        plate.size = Vec3(512, 1, 512)
        plate.color = Vec3(0.39, 0.40, 0.42)
        plate.anchored = true
        // Roblox's baseplate is locked too: clicking the ground doesn't select it.
        plate.locked = true
        return plate
    }

    /// Where players appear: every character starts at x 0, z 18.
    private static func spawnPad() -> Part {
        var pad = Part()
        pad.name = "SpawnPad"
        pad.position = Vec3(0, 0.35, 18)
        pad.size = Vec3(6, 0.3, 6)
        pad.color = Vec3(0.30, 0.62, 0.95)
        pad.anchored = true
        return pad
    }

    /// Generate's hills, a river and lakes, 512 studs across; players drop onto the land.
    private static func terrainState() -> SceneState {
        var state = emptyState()
        state.terrain.generate(centre: Vec3(0, -8, 0), size: 512, height: 90, waterLevel: 10, seed: 7)
        var clouds = CloudSettings()
        clouds.cover = 0.4
        state.lighting.clouds = clouds
        state.lighting.fogEnd = 100_000
        return state
    }

    private static func baseplateState() -> SceneState {
        var state = emptyState()
        state.parts = [baseplate(), spawnPad()]
        return state
    }

    private static func obbyState() -> SceneState {
        var state = emptyState()
        let course = SceneGroup(name: "Course", kind: .model)
        state.groups = [course]
        state.parts = [baseplate()]

        func add(_ name: String, _ position: Vec3, _ size: Vec3, _ color: Vec3,
                 material: PartMaterial = .plastic, collide: Bool = true) {
            var part = Part()
            part.name = name
            part.position = position
            part.size = size
            part.color = color
            part.material = material
            part.anchored = true
            part.canCollide = collide
            part.parentID = course.id
            state.parts.append(part)
        }
        let stone = Vec3(0.63, 0.65, 0.70), grass = Vec3(0.35, 0.68, 0.36)
        let danger = Vec3(0.95, 0.20, 0.18), go = Vec3(0.30, 0.90, 0.45), gold = Vec3(0.98, 0.78, 0.25)

        // The start, where everyone spawns, then jumps up and away along −Z.
        add("Start", Vec3(0, 0.5, 18), Vec3(12, 1, 12), grass)
        add("Jump", Vec3(0, 2, 5), Vec3(7, 1, 7), stone)
        add("Jump", Vec3(0, 3.5, -6), Vec3(6, 1, 6), stone)
        add("Jump", Vec3(4, 5, -16), Vec3(5, 1, 5), stone)
        // A platform with a kill brick across it to hop over, and the first checkpoint.
        add("Platform", Vec3(0, 5, -30), Vec3(12, 1, 16), stone)
        add("KillBrick", Vec3(0, 6, -27), Vec3(12, 1, 1.5), danger, material: .neon)
        add("Checkpoint", Vec3(0, 5.6, -34), Vec3(6, 0.2, 6), go, material: .neon, collide: false)
        // Narrow beams with kill bricks on the floor between them.
        add("Beam", Vec3(0, 6, -46), Vec3(2, 1, 12), stone)
        add("Beam", Vec3(5, 7, -58), Vec3(2, 1, 10), stone)
        add("KillBrick", Vec3(2, 3, -52), Vec3(16, 1, 30), danger, material: .neon)
        add("Platform", Vec3(5, 7, -70), Vec3(10, 1, 10), stone)
        add("Checkpoint", Vec3(5, 7.6, -70), Vec3(6, 0.2, 6), go, material: .neon, collide: false)
        // Three last jumps, each higher, to the finish.
        add("Jump", Vec3(0, 9, -80), Vec3(4, 1, 4), stone)
        add("Jump", Vec3(-6, 11, -86), Vec3(4, 1, 4), stone)
        add("Jump", Vec3(-12, 13, -92), Vec3(4, 1, 4), stone)
        add("Finish", Vec3(-12, 14, -104), Vec3(10, 1, 10), gold, material: .neon)

        // Back quickly after a kill brick: five seconds is long in an obby.
        state.starterPlayer.respawnTime = 2
        var script = ScriptObject.blank(language: .luau)
        script.name = "ObbyScript"
        script.source = obbyScript
        state.scripts.append(script)
        return state
    }

    static let obbyScript = """
    -- ObbyScript: runs the course in the Course Model. A KillBrick knocks you out, a
    -- Checkpoint is where you come back after that, and the Finish is a Win on the
    -- leaderboard and a trip back to the Start. Add more of each anywhere in Course:
    -- they work by their names.
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local Utils = require(ReplicatedStorage.Utils)

    local course = workspace.Course
    -- The checkpoint each player touched last.
    local reached = {}

    local function setUp(player)
    \tlocal leaderstats = Instance.new("Folder")
    \tleaderstats.Name = "leaderstats"
    \tleaderstats.Parent = player
    \tlocal wins = Instance.new("IntValue")
    \twins.Name = "Wins"
    \twins.Parent = leaderstats
    \t-- Back at the last checkpoint after being knocked out.
    \tplayer.CharacterAdded:Connect(function(character)
    \t\tlocal checkpoint = reached[player]
    \t\tlocal root = Utils.getRoot(character)
    \t\tif checkpoint and root then
    \t\t\troot.Position = checkpoint.Position + Vector3.new(0, 4, 0)
    \t\tend
    \tend)
    end

    for _, player in Players:GetPlayers() do
    \tsetUp(player)
    end
    Players.PlayerAdded:Connect(setUp)
    Players.PlayerRemoving:Connect(function(player)
    \treached[player] = nil
    end)

    local function knockOut(hit)
    \tlocal humanoid = Utils.getHumanoid(hit)
    \tif humanoid and humanoid.Health > 0 then
    \t\thumanoid.Health = 0
    \tend
    end

    local function checkpoint(pad)
    \treturn function(hit)
    \t\tlocal player = Utils.playerFromPart(hit)
    \t\tif player and reached[player] ~= pad then
    \t\t\treached[player] = pad
    \t\t\tprint(player.Name .. " reached a checkpoint")
    \t\tend
    \tend
    end

    for _, part in course:GetDescendants() do
    \tif part.Name == "KillBrick" then
    \t\tpart.Touched:Connect(knockOut)
    \telseif part.Name == "Checkpoint" then
    \t\tpart.Touched:Connect(checkpoint(part))
    \tend
    end

    -- Once per player every few seconds, however long they stand on it.
    local canFinish = Utils.cooldown(3)
    course.Finish.Touched:Connect(function(hit)
    \tlocal player = Utils.playerFromPart(hit)
    \tif player and canFinish(player) then
    \t\tplayer.leaderstats.Wins.Value += 1
    \t\treached[player] = nil
    \t\tprint(player.Name .. " finished the obby!")
    \t\ttask.wait(1)
    \t\tlocal root = Utils.getRoot(player)
    \t\tif root then
    \t\t\troot.Position = course.Start.Position + Vector3.new(0, 4, 0)
    \t\tend
    \tend
    end)
    """
}

extension SceneModel {
    /// A template as a new place: the old place's undo history goes with it, and
    /// nothing is selected.
    func loadTemplate(_ template: PlaceTemplate) {
        let state = template.state()
        commit("Opened \(template.title)") {
            self.state = state
            selection = []
            selectedScript = nil
            selectedShader = nil
        }
        clearHistory()
        noteChange()
        statusText = "New place from \(template.title)"
    }
}
