import AppKit
import MetalKit
import simd

/// Verification for what characters wear: the built-in catalog (meshes and pictures),
/// Roblox's clothing template on the body, the rules for a place's and a player's
/// looks, where accessories hang as the body moves, frames drawn and read back, the
/// Luau API (Accessory, Shirt, Pants, the face, HumanoidDescription), the player's
/// profile, and two players seeing each other's looks and a host script dressing a
/// joined player.
enum WardrobeSelfTest {

    static func run(check: Checker) {
        testCatalog(check)
        testTemplate(check)
        testLookRules(check)
        testAttachments(check)
        testDrawing(check)
        testPlaying(check)
        testLuau(check)
        testProfile(check)
        testTwoPlayers(check)
    }

    private static let frame: Float = 1.0 / 60

    private static func world() -> SceneModel {
        let model = SceneModel()
        model.parts = []
        model.scripts = []
        model.shaders = []
        model.groups = []
        model.starterGui = []
        model.sounds = []
        model.assets = []
        model.starterPlayer = StarterPlayerSettings()
        return model
    }

    private static func play(_ model: SceneModel) -> PlayController {
        let session = PlayController(model: model, console: ScriptConsole())
        session.start()
        step(session, seconds: 0.3)
        return session
    }

    private static func step(_ session: PlayController, seconds: Float) {
        var elapsed: Float = 0
        while elapsed < seconds {
            session.step(dt: frame)
            elapsed += frame
        }
    }

    /// Steps until a script has printed a line starting with `word` (or 4 s go by).
    private static func until(_ session: PlayController, _ word: String) {
        var elapsed: Float = 0
        while elapsed < 4, !session.console.lines.contains(where: { $0.text.hasPrefix(word + " ") }) {
            session.step(dt: frame)
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
            elapsed += frame
        }
        session.step(dt: frame)
    }

    private static func said(_ session: PlayController, _ kind: ScriptConsole.Kind = .output) -> [String] {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        return session.console.lines.filter { $0.kind == kind }.map(\.text)
    }

    private static func builtIn(_ id: String) -> String { AvatarCatalog.prefix + id }

    // MARK: - Catalog

    private static func testCatalog(_ check: Checker) {
        print("\nLooks: the built-in catalog")
        var problems: [String] = []
        for entry in AvatarCatalog.accessories {
            guard let (vertices, indices) = AvatarCatalog.mesh(entry.id), !indices.isEmpty,
                  indices.count % 3 == 0, indices.allSatisfy({ Int($0) < vertices.count }) else {
                problems.append("\(entry.id): no mesh")
                continue
            }
            if vertices.contains(where: { abs(length($0.normal) - 1) > 1e-3 }) { problems.append("\(entry.id): normals") }
            let extent = vertices.reduce(Vec3.zero) { simd_max($0, abs($1.position)) }
            if simd_reduce_max(extent) > 2.5 { problems.append("\(entry.id): \(extent) too big") }
            // Every triangle faces the way its corners' normals say (outside).
            var inward = 0
            for t in stride(from: 0, to: indices.count, by: 3) {
                let a = vertices[Int(indices[t])], b = vertices[Int(indices[t + 1])], c = vertices[Int(indices[t + 2])]
                let face = cross(b.position - a.position, c.position - a.position)
                guard length(face) > 1e-6 else { continue }
                if dot(face, a.normal + b.normal + c.normal) < 0 { inward += 1 }
            }
            if inward > 0 { problems.append("\(entry.id): \(inward) triangles inside out") }
            if AvatarAccessory(builtIn: entry.id)?.type != entry.type { problems.append("\(entry.id): type") }
        }
        check("every built-in accessory has a mesh: its size sane, wound outwards, lit the right way",
              problems.isEmpty, problems.joined(separator: "; "))

        let pictures = AvatarCatalog.faces.filter { $0.id != AvatarCatalog.classicFace && $0.id != "None" }
        check("every built-in face is a 256 × 256 picture (the classic smile and No Face are not pictures)",
              pictures.allSatisfy { AvatarCatalog.image(builtIn($0.id)).map { $0.width == 256 && $0.height == 256 } ?? false }
              && AvatarCatalog.image(builtIn(AvatarCatalog.classicFace)) == nil && AvatarCatalog.image(builtIn("None")) == nil)
        let clothes = AvatarCatalog.shirts + AvatarCatalog.pants
        check("every built-in shirt and pants is drawn on Roblox's 585 × 559 template",
              clothes.allSatisfy { AvatarCatalog.image(builtIn($0.id)).map { $0.width == 585 && $0.height == 559 } ?? false })
        func alpha(_ id: String, _ x: Int, _ y: Int) -> UInt8? {
            guard let image = AvatarCatalog.image(builtIn(id)), let pixels = image.dataProvider?.data as Data? else { return nil }
            return pixels[y * image.bytesPerRow + x * 4 + 3]
        }
        check("…a tee covers the torso and the tops of the arms, not the hands",
              alpha("Tee", 295, 138) == 255 && alpha("Tee", 249, 370) == 255 && alpha("Tee", 249, 470) == 0,
              "\(String(describing: alpha("Tee", 295, 138))) \(String(describing: alpha("Tee", 249, 470)))")
        check("…shorts stop at the knee, jeans don't",
              alpha("Shorts", 249, 370) == 255 && alpha("Shorts", 249, 470) == 0 && alpha("Jeans", 249, 470) == 255)
    }

    // MARK: - The template on the body

    private static func testTemplate(_ check: Checker) {
        print("\nLooks: the clothing template")
        let torso = MeshFactory.clothedBox(size: Vec3(2, 2, 1), radius: 0.2, regions: ClothingTemplate.torso)
        func uv(near point: Vec3, facing normal: Vec3, in mesh: (vertices: [Vertex], indices: [UInt32], uvs: [SIMD2<Float>]))
            -> SIMD2<Float> {
            let best = mesh.vertices.indices.filter { dot(mesh.vertices[$0].normal, normal) > 0.99 }
                .min { simd_distance(mesh.vertices[$0].position, point) < simd_distance(mesh.vertices[$1].position, point) }!
            return mesh.uvs[best] * SIMD2(ClothingTemplate.width, ClothingTemplate.height)
        }
        // The flat part of each face ends 0.2 studs (the rounding) in from its edges: a
        // tenth of the way across the torso's front.
        let chestRight = uv(near: Vec3(0.8, 0.8, -0.5), facing: Vec3(0, 0, -1), in: torso)
        let hipLeft = uv(near: Vec3(-0.8, -0.8, -0.5), facing: Vec3(0, 0, -1), in: torso)
        let backRight = uv(near: Vec3(0.8, 0.8, 0.5), facing: Vec3(0, 0, 1), in: torso)
        let topFront = uv(near: Vec3(0.8, 1, -0.3), facing: Vec3(0, 1, 0), in: torso)
        check("the torso's front is the template's front square, the character's right on its left",
              simd_distance(chestRight, SIMD2(243.8, 86.8)) < 0.5 && simd_distance(hipLeft, SIMD2(346.2, 189.2)) < 0.5,
              "\(chestRight) \(hipLeft)")
        check("…its back the back square (seen from behind), its top the strip above the front",
              simd_distance(backRight, SIMD2(542.2, 86.8)) < 0.5 && simd_distance(topFront, SIMD2(243.8, 59.2)) < 0.5,
              "\(backRight) \(topFront)")
        let arm = MeshFactory.clothedBox(size: Vec3(1, 2, 1), radius: 0.24, regions: ClothingTemplate.right)
        let armFront = uv(near: Vec3(0.26, 0.76, -0.5), facing: Vec3(0, 0, -1), in: arm)
        let hand = uv(near: Vec3(0.26, -1, -0.26), facing: Vec3(0, -1, 0), in: arm)
        check("the right arm's front and hand are where Roblox's template puts them",
              simd_distance(armFront, SIMD2(232.36, 370.36)) < 0.5 && simd_distance(hand, SIMD2(232.36, 500.36)) < 0.5,
              "\(armFront) \(hand)")
        let decal = MeshFactory.faceDecal()
        let middle = decal.vertices.indices.min { length(decal.uvs[$0] - SIMD2(0.5, 0.5)) < length(decal.uvs[$1] - SIMD2(0.5, 0.5)) }!
        let leftOfPicture = decal.vertices.indices.min { length(decal.uvs[$0] - SIMD2(0, 0.5)) < length(decal.uvs[$1] - SIMD2(0, 0.5)) }!
        check("a face picture goes on the front of the head, just above it, the picture's left on the character's right",
              decal.vertices[middle].position.z < -0.62 && decal.vertices[middle].position.z > -0.64
              && decal.vertices[leftOfPicture].position.x > 0.4,
              "\(decal.vertices[middle].position) \(decal.vertices[leftOfPicture].position)")
    }

    // MARK: - Rules

    private static func testLookRules(_ check: Checker) {
        print("\nLooks: a place's and a player's")
        var place = AvatarLook()
        place.shirt = "studio://Uniform"
        place.accessories = [AvatarAccessory(builtIn: "Medal")!]
        var player = AvatarLook()
        player.face = builtIn("Grin")
        player.shirt = builtIn("Hoodie")
        player.pants = builtIn("Jeans")
        player.accessories = [AvatarAccessory(builtIn: "Cap")!]
        let worn = place.worn(by: player, playersWearOwn: true)
        check("a player wears their own look, the place's shirt in place of theirs, the place's medal as well as their cap",
              worn.face == builtIn("Grin") && worn.shirt == "studio://Uniform" && worn.pants == builtIn("Jeans")
              && worn.accessories.map(\.name) == ["Cap", "Medal"])
        let placeOnly = place.worn(by: player, playersWearOwn: false)
        check("…and only the place's when it says so",
              placeOnly.face.isEmpty && placeOnly.pants.isEmpty && placeOnly.accessories.map(\.name) == ["Medal"])
        var crowded = AvatarLook()
        crowded.accessories = (0..<14).map { _ in AvatarAccessory(builtIn: "Crown")! }
        crowded.tidy()
        check("no more than ten accessories at once", crowded.accessories.count == AvatarLook.mostAccessories)

        var mixed = player
        mixed.face = "studio://MyFace"
        mixed.accessories.append(AvatarAccessory(name: "Hat", item: "studio://Hat", type: .hat, color: .zero))
        let own = mixed.builtInOnly
        check("a player's own look keeps only built-in things (a place's files stay in the place)",
              own.face.isEmpty && own.shirt == builtIn("Hoodie") && own.accessories.map(\.name) == ["Cap"])
        check("an imported model as an accessory starts sat down on the head",
              AvatarAccessory(name: "Hat", item: "studio://Hat", type: .hat, color: .zero).offset.y < 0
              && AvatarAccessory(builtIn: "TopHat")!.offset == .zero)

        var settings = StarterPlayerSettings()
        settings.look = worn
        settings.playersWearOwnLook = false
        let saved = try? JSONEncoder().encode(settings)
        let reopened = saved.flatMap { try? JSONDecoder().decode(StarterPlayerSettings.self, from: $0) }
        let old = try? JSONDecoder().decode(StarterPlayerSettings.self, from: Data("{\"walkSpeed\":20}".utf8))
        check("StarterPlayer's look is saved with the scene; an older scene's characters wear nothing new",
              reopened?.look == worn && reopened?.playersWearOwnLook == false
              && old?.look.isEmpty == true && old?.playersWearOwnLook == true)
        let value = worn.scriptValue
        check("a look goes to scripts and back unchanged", AvatarLook(scriptValue: value) == worn)

        let model = world()
        guard let picture = try? model.importAsset(data: AudioSelfTest.png(red: 1, green: 0, blue: 0), name: "Uniform",
                                                   fileExtension: "png") else { return }
        model.starterPlayer.look = worn
        model.renameAsset(picture, to: "Kit")
        check("renaming an imported picture takes StarterPlayer's look with it",
              model.starterPlayer.look.shirt == "studio://Kit")
        model.undo()
        check("…and undo takes it back", model.starterPlayer.look.shirt == "studio://Uniform")
    }

    // MARK: - Where accessories hang

    private static func testAttachments(_ check: Checker) {
        print("\nLooks: accessories on the body")
        var pose = AvatarPose(position: Vec3(10, 0, 0), yaw: 0, joints: AvatarJoints())
        pose.look.accessories = [AvatarAccessory(builtIn: "TopHat")!, AvatarAccessory(builtIn: "Backpack")!,
                                 AvatarAccessory(name: "Box", item: "studio://Box", type: .hat, color: .zero)]
        pose.look.accessories[2].offset = .zero
        func place(_ pose: AvatarPose) -> [String: Vec3] {
            let placed = pose.accessoryTransforms { $0.item.hasPrefix(AvatarCatalog.prefix) ? .some(nil) : .some(Vec3(2, 1, 2)) }
            return Dictionary(placed.map { ($0.accessory.name, Vec3($0.matrix.columns.3.x, $0.matrix.columns.3.y,
                                                                    $0.matrix.columns.3.z)) },
                              uniquingKeysWith: { first, _ in first })
        }
        let standing = place(pose)
        check("a hat hangs from the top of the head, a backpack from the middle of the back",
              simd_distance(standing["TopHat"] ?? .zero, Vec3(10, 4.65 + 0.625, 0)) < 0.01
              && simd_distance(standing["Backpack"] ?? .zero, Vec3(10, 3, 0.5)) < 0.01,
              "\(standing)")
        let box = pose.accessoryTransforms { _ in .some(Vec3(2, 1, 2)) }.first { $0.accessory.name == "Box" }!.matrix
        let bottom = box * Vec4(0, -0.5, 0, 1)
        check("an imported model sits its bottom on the head, at its own size",
              abs(bottom.y - 5.275) < 0.01 && abs((box * Vec4(0.5, 0, 0, 1)).x - 11) < 0.01, "\(bottom)")
        var turned = pose
        turned.yaw = .pi / 2
        turned.joints.neck = Vec3(0.5, 0, 0)
        let facing = place(turned)
        check("accessories turn with the body and nod with the head",
              abs((facing["Backpack"] ?? .zero).x - 10) > 0.4 && simd_distance(facing["TopHat"] ?? .zero, standing["TopHat"] ?? .zero) > 0.1,
              "\(facing)")
        var fallen = pose
        fallen.dead = true
        check("…and lie down with it", (place(fallen)["TopHat"]?.y ?? 9) < 1.5, "\(place(fallen))")
        var missing = pose
        missing.look.accessories = [AvatarAccessory(name: "Gone", item: "studio://Gone", type: .hat, color: .zero)]
        check("an accessory whose model can't be found is left off", missing.accessoryTransforms { _ in nil }.isEmpty)
    }

    // MARK: - Drawn

    private final class Source: ViewportSource {
        let model: SceneModel
        var renderCamera: Camera
        var avatars: [AvatarPose]
        let shaderStatus = ShaderStatusStore()
        let shaderConsole = ScriptConsole()
        var editorOverlay: EditorOverlay? { nil }
        func stepFrame() {}
        init(model: SceneModel, avatars: [AvatarPose], camera: Camera) {
            self.model = model
            self.avatars = avatars
            self.renderCamera = camera
        }
    }

    private static func render(_ model: SceneModel, _ avatars: [AvatarPose], camera: Camera) -> ((Vec3) -> Vec3, Bool)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let width = 480, height = 480
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: width, height: height), device: device)
        let source = Source(model: model, avatars: avatars, camera: camera)
        guard let renderer = Renderer(device: device, view: view, source: source),
              let image = renderer.snapshot(width: width, height: height),
              let data = image.dataProvider?.data as Data? else { return nil }
        let pixels = [UInt8](data)
        withExtendedLifetime(source) {}
        let colour = { (point: Vec3) -> Vec3 in
            let clip = camera.viewProjection(aspect: 1) * Vec4(point, 1)
            let x = Int(((clip.x / clip.w + 1) / 2 * Float(width)).rounded())
            let y = Int(((1 - clip.y / clip.w) / 2 * Float(height)).rounded())
            let i = (min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)) * 4
            return Vec3(Float(pixels[i + 2]), Float(pixels[i + 1]), Float(pixels[i])) / 255
        }
        return (colour, renderer.drewRayTraced)
    }

    private static func testDrawing(_ check: Checker) {
        print("\nLooks: drawn")
        let model = world()
        model.showGrid = false
        guard (try? model.importAsset(data: AudioSelfTest.png(red: 1, green: 0, blue: 0), name: "RedShirt",
                                      fileExtension: "png")) != nil,
              (try? model.importAsset(data: AudioSelfTest.png(red: 0, green: 0, blue: 1), name: "BluePants",
                                      fileExtension: "png")) != nil else {
            check("pictures to wear", false)
            return
        }
        var pose = AvatarPose(position: .zero, yaw: .pi, joints: AvatarJoints())
        var green = BodyColors()
        for part in BodyColors.partNames { green[part] = Vec3(0.1, 0.8, 0.1) }
        pose.colors = green
        var camera = Camera()
        camera.target = Vec3(0, 3.4, 0)
        camera.yaw = .pi / 2
        camera.pitch = 0.05
        camera.distance = 11
        guard let (bare, _) = render(model, [pose], camera: camera) else {
            check("the renderer draws", false)
            return
        }
        let chest = Vec3(0, 3.2, -0.55), shin = Vec3(-0.5, 0.6, -0.55), hatCrown = Vec3(0, 5.9, -0.7)
        let arm = Vec3(1.5, 2.7, -0.55)
        check("(bare: green body, the sky above the head)",
              bare(chest).y > bare(chest).x * 2 && bare(hatCrown).z > bare(hatCrown).x, "\(bare(chest)) \(bare(hatCrown))")

        pose.look.shirt = "studio://RedShirt"
        pose.look.pants = "studio://BluePants"
        pose.look.face = builtIn("Cool")
        pose.look.accessories = [AvatarAccessory(builtIn: "TopHat")!]
        guard let (dressed, _) = render(model, [pose], camera: camera) else { return }
        let top = dressed(chest), legs = dressed(shin), sleeve = dressed(arm), hat = dressed(hatCrown)
        check("a shirt is drawn on the torso and arms, over the pants", top.x > top.y * 2 && top.x > top.z * 2
              && sleeve.x > sleeve.y * 2, "\(top) \(sleeve)")
        check("pants on the legs", legs.z > legs.x * 2 && legs.z > legs.y * 1.5, "\(legs)")
        check("a top hat above the head", simd_reduce_max(hat) < 0.2, "\(hat)")
        // The outer halves of the Cool face's sunglasses, beside where the classic smile's
        // eyes are: skin on a bare head.
        let bridge = [Vec3(0.34, 4.78, -0.53), Vec3(-0.34, 4.78, -0.53)]
        let darkest = bridge.map { simd_reduce_max(dressed($0)) }.max() ?? 1
        let bareDarkest = bridge.map { simd_reduce_max(bare($0)) }.min() ?? 1
        check("a face picture replaces the classic smile", darkest < 0.25 && bareDarkest > 0.35,
              "\(darkest) \(bareDarkest)")

        model.lighting.technology = .rayTraced
        if let (traced, rayTraced) = render(model, [pose], camera: camera), rayTraced {
            check("…all of it ray traced too", traced(chest).x > traced(chest).y * 2 && simd_reduce_max(traced(hatCrown)) < 0.25,
                  "\(traced(chest)) \(traced(hatCrown))")
        }
    }

    // MARK: - In play

    private static func testPlaying(_ check: Checker) {
        print("\nLooks: in play")
        let model = world()
        model.starterPlayer.look.shirt = builtIn("Suit")
        model.starterPlayer.look.accessories = [AvatarAccessory(builtIn: "TopHat")!]
        var own = AvatarLook()
        own.face = builtIn("Wink")
        own.shirt = builtIn("Tee")
        own.accessories = [AvatarAccessory(builtIn: "Glasses")!]
        let session = PlayController(model: model, console: ScriptConsole())
        session.playerLook = own
        session.start()
        step(session, seconds: 0.1)
        let look = session.avatars[0].look
        check("a character wears StarterPlayer's look over the player's own",
              look.shirt == builtIn("Suit") && look.face == builtIn("Wink")
              && look.accessories.map(\.name) == ["Glasses", "TopHat"], "\(look)")
        session.look.accessories = []
        _ = session.playerInvoke("player.load", [])
        step(session, seconds: 0.05)
        check("the next character is dressed afresh", session.avatars[0].look.accessories.count == 2)
        session.stop()

        let editor = AnimationEditor(model: model)
        model.selectedAnimation = model.addAnimation()
        editor.isOpen = true
        check("the Animation Editor's rig wears StarterPlayer's look", editor.rigPose()?.look == model.starterPlayer.look)
    }

    // MARK: - Luau

    private static func testLuau(_ check: Checker) {
        print("\nLooks: Luau")
        let model = world()
        _ = try? model.importAsset(data: MeshSelfTest.cube, name: "Box", fileExtension: "obj")
        var script = ScriptObject.blank(language: .luau)
        script.host = .starterCharacter
        script.source = """
        local character = script.Parent
        local humanoid = character:WaitForChild("Humanoid")

        local hat = Instance.new("Accessory")
        hat.Name = "Topper"
        hat.MeshId = "builtin://TopHat"
        print("new", hat.ClassName, hat.Parent == nil, hat.AccessoryType.Name, hat:IsA("Accessory"))
        humanoid:AddAccessory(hat)
        print("worn", hat.Parent == character, character.Topper == hat, #humanoid:GetAccessories())
        hat.Color = Color3.new(1, 0, 0)
        hat.Offset = Vector3.new(0, 0.5, 0)

        local box = Instance.new("Accessory")
        box.MeshId = "studio://Box"
        box.AccessoryType = Enum.AccessoryType.Back
        box.Parent = character
        print("box", box.AccessoryType.Name, #character:GetChildren() >= 9)

        local shirt = Instance.new("Shirt")
        shirt.ShirtTemplate = "builtin://Hoodie"
        shirt.Parent = character
        local pants = Instance.new("Pants", character)
        pants.PantsTemplate = "builtin://Jeans"
        print("clothes", character.Shirt.ShirtTemplate, character:FindFirstChildOfClass("Pants").PantsTemplate)
        print("face", character.Head.face.Texture)
        character.Head.face.Texture = "builtin://Grin"

        local ok, message = pcall(function() hat.Parent = workspace end)
        print("elsewhere", ok, message:find("character") ~= nil)
        ok = pcall(function() hat.AccessoryType = "Nope" end)
        print("bad type", ok)

        local description = humanoid:GetAppliedDescription()
        print("described", description.Shirt, description.HatAccessory, description.BackAccessory, description.Face)

        task.wait(0.5)
        box:Destroy()
        print("gone", box.Parent == nil, character:FindFirstChild("Box") == nil, #humanoid:GetAccessories())

        task.wait(0.5)
        local outfit = Instance.new("HumanoidDescription")
        outfit.Shirt = "builtin://Suit"
        outfit.HatAccessory = "builtin://Crown,builtin://Glasses"
        outfit.TorsoColor = Color3.new(0, 0, 1)
        humanoid:ApplyDescription(outfit)
        print("applied", #humanoid:GetAccessories(), character.Shirt.ShirtTemplate, character:FindFirstChild("Pants") == nil)

        task.wait(0.5)
        humanoid:RemoveAccessories()
        character.Shirt:Destroy()
        character.Head.face:Destroy()
        print("bare", #humanoid:GetAccessories(), character:FindFirstChild("Shirt") == nil,
        \tcharacter.Head:FindFirstChild("face") == nil)
        """
        model.scripts.append(script)
        let session = play(model)
        let first = session.avatars[0].look
        step(session, seconds: 0.1)
        func line(_ prefix: String) -> String { said(session).first { $0.hasPrefix(prefix + " ") } ?? "(no \(prefix))" }
        check("Instance.new(\"Accessory\"): a built-in MeshId brings its type; AddAccessory puts it on the character",
              line("new") == "new Accessory true Hat true" && line("worn") == "worn true true 1",
              line("new") + " | " + line("worn"))
        check("…parenting to the character wears one too, and it's among the character's children",
              line("box") == "box Back true", line("box"))
        check("Shirt and Pants, parented to the character, and the Head's face Decal",
              line("clothes") == "clothes builtin://Hoodie builtin://Jeans" && line("face") == "face builtin://Smile",
              line("clothes") + " | " + line("face"))
        check("…an accessory goes only on a character, and its type must be one",
              line("elsewhere") == "elsewhere false true" && line("bad type") == "bad type false",
              line("elsewhere") + " | " + line("bad type"))
        check("GetAppliedDescription describes what's worn",
              line("described") == "described builtin://Hoodie builtin://TopHat studio://Box builtin://Grin",
              line("described"))
        let hat = first.accessories.first { $0.name == "Topper" }
        check("what scripts put on is what's drawn: its colour, where it sits, the clothes and face",
              hat?.color == Vec3(1, 0, 0) && hat?.offset.y == 0.5 && first.shirt == builtIn("Hoodie")
              && first.pants == builtIn("Jeans") && first.face == builtIn("Grin"), "\(first)")
        until(session, "gone")
        check("Destroy takes an accessory off", line("gone") == "gone true true 1", line("gone"))
        until(session, "applied")
        check("ApplyDescription dresses the character all at once, body colours included",
              line("applied") == "applied 2 builtin://Suit true"
              && session.avatars[0].look.accessories.map(\.item) == [builtIn("Crown"), builtIn("Glasses")]
              && session.bodyColors.torso == Vec3(0, 0, 1), line("applied"))
        until(session, "bare")
        let bare = session.avatars[0].look
        check("RemoveAccessories, and destroying the Shirt and the face",
              line("bare") == "bare 0 true true" && bare.accessories.isEmpty && bare.shirt.isEmpty
              && bare.face == AvatarCatalog.noFaceReference, line("bare"))
        check("…with no errors", said(session, .error).isEmpty, "\(said(session, .error))")
        session.stop()
    }

    // MARK: - The player's profile

    private static func testProfile(_ check: Checker) {
        print("\nLooks: the player's profile")
        let suite = "StudioWardrobeTest-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defer { defaults.removePersistentDomain(forName: suite) }
        var profile = PlayerProfile()
        profile.look.face = builtIn("Cool")
        profile.look.accessories = [AvatarAccessory(builtIn: "Crown")!,
                                    AvatarAccessory(name: "Mine", item: "studio://Mine", type: .hat, color: .zero)]
        profile.save(to: defaults)
        let loaded = PlayerProfile.load(from: defaults)
        check("a player's look is kept between launches (built-in things only)",
              loaded.look.face == builtIn("Cool") && loaded.look.accessories.map(\.name) == ["Crown"])
        let old = try? JSONDecoder().decode(PlayerProfile.self, from: Data("{\"name\":\"Old\"}".utf8))
        check("…and a profile from before looks still loads", old?.name == "Old" && old?.look.isEmpty == true)

        let model = world()
        model.starterPlayer.look.pants = builtIn("Shorts")
        let session = PlayController(model: model, console: ScriptConsole())
        loaded.apply(to: model, session)
        session.start()
        step(session, seconds: 0.05)
        check("the client dresses the player in it, with the place's pants",
              session.look.face == builtIn("Cool") && session.look.pants == builtIn("Shorts"))
        session.stop()
    }

    // MARK: - Two players

    private static func testTwoPlayers(_ check: Checker) {
        print("\nLooks: joined players")
        var robin = AvatarLook()
        robin.accessories = [AvatarAccessory(builtIn: "TopHat")!]
        robin.shirt = builtIn("Suit")
        var sam = AvatarLook()
        sam.face = builtIn("Grin")
        sam.accessories = [AvatarAccessory(builtIn: "Cap")!]
        guard let (hosting, joining) = LANSelfTest.twoPlayers({ model in
            model.starterPlayer.look.accessories = [AvatarAccessory(builtIn: "Medal")!]
            var script = ScriptObject.blank(language: .luau)
            script.source = """
            local Players = game:GetService("Players")
            game:GetService("UserInputService").InputBegan:Connect(function(input)
            \tif input.KeyCode ~= Enum.KeyCode.P then
            \t\treturn
            \tend
            \tfor _, player in Players:GetPlayers() do
            \t\tif player.Name == "Sam" then
            \t\t\tlocal humanoid = player.Character.Humanoid
            \t\t\tlocal crown = Instance.new("Accessory")
            \t\t\tcrown.Name = "Winner"
            \t\t\tcrown.MeshId = "builtin://Crown"
            \t\t\thumanoid:AddAccessory(crown)
            \t\t\tplayer.Character.Head.face.Texture = "builtin://Happy"
            \t\t\tprint("crowned", #humanoid:GetAccessories(), player.Character.Winner == crown,
            \t\t\t\tplayer.Character.Head.face.Texture)
            \t\tend
            \tend
            end)
            """
            model.scripts.append(script)
        }, looks: (robin, sam)), let host = hosting.player, let player = joining.player else {
            check("a host and a player join", false)
            return
        }
        LANSelfTest.run([hosting, joining], seconds: 0.6)
        let samSeen = host.avatars.dropFirst().first?.look
        let robinSeen = player.avatars.dropFirst().first?.look
        check("each player wears their own look and the place's medal, and each sees the other's",
              samSeen?.face == builtIn("Grin") && samSeen?.accessories.map(\.name) == ["Cap", "Medal"]
              && robinSeen?.shirt == builtIn("Suit") && robinSeen?.accessories.map(\.name) == ["TopHat", "Medal"],
              "\(String(describing: samSeen)) \(String(describing: robinSeen))")
        host.key("P", pressed: true)
        host.step(dt: 1.0 / 60)
        host.key("P", pressed: false)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let crowned = host.console.lines.filter { $0.kind == .output }.map(\.text).first { $0.hasPrefix("crowned") }
        check("a host script dressing a joined player reads back what it put on at once",
              crowned == "crowned 3 true builtin://Happy", "\(String(describing: crowned))")
        LANSelfTest.run([hosting, joining], seconds: 0.5)
        check("…which is what that player's game then has, and what the host draws",
              player.look.accessories.map(\.name) == ["Cap", "Medal", "Winner"] && player.look.face == builtIn("Happy")
              && host.avatars.dropFirst().first?.look.accessories.count == 3,
              "\(player.look.accessories.map(\.name))")
        check("…with no errors on either", host.console.lines.filter { $0.kind == .error }.isEmpty
              && player.console.lines.filter { $0.kind == .error }.isEmpty,
              "\(host.console.lines.filter { $0.kind == .error }.map(\.text))")
        hosting.leaveGame()
        joining.leaveGame()
    }
}
