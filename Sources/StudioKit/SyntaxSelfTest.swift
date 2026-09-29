import Foundation

/// Verification for the Wren lexer used by syntax highlighting, and for the
/// completion engine behind the editor's suggestions.
enum SyntaxSelfTest {

    static func run(check: Checker) {
        testTokenRanges(check)
        testKeywordsAndTypes(check)
        testComments(check)
        testStrings(check)
        testNumbers(check)
        testCommentAndStringDetection(check)
        testPartialWord(check)
        testStaticMembers(check)
        testInferredLocals(check)
        testChains(check)
        testGlobalCompletion(check)
        testCompletionRestraint(check)
        testShippedSourcesTokenize(check)
        testMetalLexer(check)
        testMetalCompletion(check)
        testLuauLexer(check)
        testLuauCompletion(check)
        testModules(check)
        testServices(check)
        testNewFeatureAPI(check)
    }

    private static func testNewFeatureAPI(_ check: Checker) {
        print("\nCompletion: lights, solids and world GUI")
        let probes: [(String, String)] = [
            ("local lamp = Instance.new('SpotLight')\nlamp.", "Angle"),
            ("local lamp = Instance.new('SurfaceLight')\nlamp.", "Face"),
            ("local p = Instance.new('Part')\np:", "UnionAsync(parts, collisionFidelity)"),
            ("local p: UnionOperation = workspace.Result\np.", "UsePartColor"),
            ("local p: NegateOperation = workspace.Cutter\np.", "CollisionFidelity"),
            ("local gui = Instance.new('SurfaceGui')\ngui.", "PixelsPerStud"),
            ("local gui = Instance.new('SurfaceGui')\ngui.", "CanvasSize"),
            ("local view = Instance.new('ViewportFrame')\nview.", "CurrentCamera"),
            ("local camera = Instance.new('Camera')\ncamera.", "FieldOfView"),
            ("Enum.SurfaceGuiSizingMode.", "PixelsPerStud"),
            ("Enum.CollisionFidelity.", "PreciseConvexDecomposition")
        ]
        for (source, expected) in probes {
            let labels = LuauCompletion.items(in: source, caret: (source as NSString).length).map(\.label)
            check("completion offers \(expected) for \(source.components(separatedBy: "\n").first ?? source)", labels.contains(expected), "\(labels)")
        }
    }

    private static func testServices(_ check: Checker) {
        print("\nCompletion: GetService")
        func items(_ source: String, caret: Int? = nil) -> [CompletionItem] {
            LuauCompletion.items(in: source, caret: caret ?? (source as NSString).length)
        }
        func labels(_ source: String) -> [String] { items(source).map(\.label) }
        func insert(_ label: String, _ source: String, caret: Int? = nil) -> String? {
            items(source, caret: caret).first { $0.label == label }?.insert
        }

        check("GetService(\" lists every service", Set(labels("game:GetService(\"")) == Set(LuauAPI.services.keys),
              "\(labels("game:GetService(\""))")
        check("…in order", labels("game:GetService(\"").prefix(3) == ["Animations", "DataStoreService", "Lighting"],
              "\(labels("game:GetService(\"").prefix(3))")
        check("…closing the string and the call", insert("Players", "game:GetService(\"") == "Players\")")
        check("…or not, when they're closed", insert("Players", "game:GetService(\"\")", caret: 17) == "Players")
        check("…with single quotes too", insert("Players", "game:GetService('") == "Players')")
        check("…narrowed as it's typed", labels("game:GetService(\"Tw") == ["TweenService"])
        check("the one named like the local being declared comes first",
              labels("local TweenService = game:GetService(\"").first == "TweenService")
        let have = "local RunService = game:GetService(\"RunService\")\nlocal Players = game:GetService(\"Players\")\n"
        check("…and those the script already has come last",
              labels(have + "local x = game:GetService(\"").suffix(2) == ["Players", "RunService"],
              "\(labels(have + "local x = game:GetService(\""))")
        check("before the quote, it's put in for you", insert("Lighting", "local Lighting = game:GetService(") == "\"Lighting\")")
        check("…without a second )", insert("Lighting", "game:GetService()", caret: 16) == "\"Lighting\"")
        check("…first by the local's name there too", labels("local Lighting = game:GetService(").first == "Lighting")
        check("…narrowed by what's typed", labels("game:GetService(Ru") == ["RunService"])
        check("each suggestion knows what it gives", items("game:GetService(\"").first { $0.label == "Players" }?.returns == "Players")
        check("GetService on its own isn't a method call", !items("GetService(").contains { $0.detail == "service" })
        check("an ordinary string still has nothing", labels("print(\"Pla").isEmpty)
        check("and what it gives goes on resolving", luauLabels("game:GetService(\"LogService\").").contains("MessageOut"))
        // Every service offered must be one GetService really has.
        ScriptSelfTest.assertAll(check, "every suggested service is one the game has",
                                 LuauAPI.services.keys.sorted().map { "game:GetService('\($0)') ~= nil" })
    }

    // MARK: - Modules and the scene

    static let utilsModule = """
    -- Utils: small helpers.
    local Utils = {}
    Utils.VERSION = "1.2"
    Utils.speed = 16
    Utils.colours = { red = Color3.new(1, 0, 0), blue = Color3.new(0, 0, 1) }
    Utils.origin = Vector3.new(0, 0, 0)

    local function clamp01(x)
    \treturn math.clamp(x, 0, 1)
    end
    Utils.clamp01 = clamp01

    function Utils.lerp(a: number, b: number, t: number): number
    \tif t > 1 then
    \t\treturn b -- not the module's return
    \tend
    \treturn a + (b - a) * t
    end

    function Utils:describe()
    \treturn "utils"
    end

    Utils.__private = true
    return Utils
    """

    static let configModule = """
    return {
    \tmaxPlayers = 8,
    \tspawn = Vector3.new(0, 5, 0),
    \tgreet = function(name) return "hi " .. name end,
    \tdebug = false,
    \tcheck = function(a) return a == 1 end,
    }
    """

    static let enemyModule = """
    local Enemy = {}
    Enemy.__index = Enemy

    function Enemy.new(name, health)
    \tlocal self = setmetatable({}, Enemy)
    \tself.name = name
    \tself.health = health or 100
    \treturn self
    end

    function Enemy:TakeDamage(amount)
    \tself.health -= amount
    \tif self.health <= 0 then
    \t\tself:Die()
    \tend
    end

    function Enemy:Die()
    \tprint(self.name .. " is gone")
    end

    return Enemy
    """

    /// ReplicatedStorage with Utils, a Shared folder holding Config, and a RemoteEvent;
    /// Script Service with the Enemy class and the script being edited; a Tower in the
    /// Workspace with a Door and a part whose name has a space.
    static func sampleScene() -> LuauScene {
        var scene = LuauScene()
        let replicated = scene.places["ReplicatedStorage"]!
        let shared = scene.add(.init(name: "Shared", className: "Folder", parent: replicated))
        scene.add(.init(name: "Utils", className: "ModuleScript", parent: replicated, source: utilsModule))
        scene.add(.init(name: "Config", className: "ModuleScript", parent: shared, source: configModule))
        scene.add(.init(name: "Notify", className: "RemoteEvent", parent: replicated))
        let service = scene.places["ServerScriptService"]!
        scene.add(.init(name: "Enemy", className: "ModuleScript", parent: service, source: enemyModule))
        scene.script = scene.add(.init(name: "Main", className: "Script", parent: service))
        let tower = scene.add(.init(name: "Tower", className: "Model", parent: scene.places["Workspace"]!))
        scene.add(.init(name: "Door", className: "Part", parent: tower))
        scene.add(.init(name: "Left Arm", className: "Part", parent: tower))
        return scene
    }

    private static func testModules(_ check: Checker) {
        print("\nCompletion: modules, require and the scene")
        let scene = sampleScene()
        func items(_ source: String, caret: Int? = nil) -> [CompletionItem] {
            LuauCompletion.items(in: source, caret: caret ?? (source as NSString).length, scene: scene)
        }
        func labels(_ source: String) -> [String] { items(source).map(\.label) }
        func insert(_ label: String, _ source: String) -> String? { items(source).first { $0.label == label }?.insert }

        // Reading a module.
        let utils = LuauModuleShape.members(of: utilsModule)
        let names = utils.map(\.name)
        check("a module's values and functions are read", Set(names) == ["VERSION", "speed", "colours", "origin",
                                                                            "clamp01", "lerp", "describe", "__private"],
              "\(names)")
        check("…its functions with their parameters, types left out",
              utils.first { $0.name == "lerp" }?.parameters == "a, b, t", "\(utils.first { $0.name == "lerp" }.map { "\($0)" } ?? "-")")
        check("…a local function handed out keeps its parameters", utils.first { $0.name == "clamp01" }?.parameters == "x")
        check("…values with what they are", utils.first { $0.name == "VERSION" }?.detail == "string"
                && utils.first { $0.name == "speed" }?.detail == "number" && utils.first { $0.name == "origin" }?.detail == "Vector3")
        check("…a table's own fields", utils.first { $0.name == "colours" }?.fields.map(\.name) == ["red", "blue"])
        check("…and a colon function is a method", utils.first { $0.name == "describe" }?.isMethod == true)
        let config = LuauModuleShape.members(of: configModule).map(\.name)
        check("a module returning a table outright", config == ["maxPlayers", "spawn", "greet", "debug", "check"], "\(config)")
        check("an if-expression isn't a block", LuauModuleShape.members(of: """
            local M = {}
            function M.sign(x)
            \treturn if x < 0 then -1 elseif x > 0 then 1 else 0
            end
            M.mode = if true then "fast" else "slow"
            if M.mode == "fast" then
            \tM.speed = 2
            end
            return M
            """).map(\.name) == ["sign", "mode"])
        check("a return inside a function isn't the module's", LuauModuleShape.members(of: "local M = {}\nfunction M.f()\n\treturn 1\nend\nreturn M").map(\.name) == ["f"])
        check("a module that returns nothing useful has no members", LuauModuleShape.members(of: "print('hi')").isEmpty
                && LuauModuleShape.members(of: "return 5").isEmpty)
        let enemy = LuauModuleShape.members(of: enemyModule)
        check("a class's constructor makes objects with its methods and fields",
              Set(enemy.first { $0.name == "new" }?.makes.map(\.name) ?? []) == ["TakeDamage", "Die", "name", "health"],
              "\(enemy.first { $0.name == "new" }?.makes.map(\.name) ?? [])")

        // require( lists every ModuleScript, as the path from this script.
        let required = items("local x = require(")
        check("require( lists every ModuleScript", Set(required.filter { $0.kind == .module }.map(\.label)) == ["Utils", "Config", "Enemy"],
              "\(required.prefix(6).map(\.label))")
        check("…before anything else", required.prefix(3).allSatisfy { $0.kind == .module }, "\(required.prefix(4).map(\.label))")
        check("…one beside the script through script.Parent", insert("Enemy", "local x = require(") == "script.Parent.Enemy)",
              insert("Enemy", "local x = require(") ?? "-")
        check("…one elsewhere through GetService", insert("Utils", "local x = require(") == "game:GetService(\"ReplicatedStorage\").Utils)",
              insert("Utils", "local x = require(") ?? "-")
        let withLocal = "local ReplicatedStorage = game:GetService(\"ReplicatedStorage\")\nlocal x = require("
        check("…or through the script's own local for the place", insert("Config", withLocal) == "ReplicatedStorage.Shared.Config)",
              insert("Config", withLocal) ?? "-")
        check("…with where it is beside it", items(withLocal).first { $0.label == "Config" }?.detail == "ReplicatedStorage.Shared")
        check("…then only what a path can start from", Set(labels(withLocal).dropFirst(3)) == ["ReplicatedStorage", "script", "game", "workspace"],
              "\(labels(withLocal))")
        check("…narrowed by name", labels("local x = require(Ut").first == "Utils")
        check("a local isn't offered on the line that declares it", !labels("local count = 0\nlocal counter = cou").contains("counter")
                && labels("local count = 0\nlocal counter = cou").first == "count")
        check("…and no second ) when one is there", LuauCompletion.items(in: "local x = require()", caret: 18, scene: scene)
                .first { $0.label == "Utils" }?.insert == "game:GetService(\"ReplicatedStorage\").Utils")
        check("without the scene, require( offers no modules", !LuauCompletion.items(in: "require(", caret: 8).contains { $0.kind == .module })

        // The places, by what's really in them.
        let rs = "local RS = game:GetService(\"ReplicatedStorage\")\n"
        check("a place lists what's in it", labels(rs + "RS.") == ["Notify", "Shared", "Utils"], "\(labels(rs + "RS."))")
        check("…each as what it is", items(rs + "RS.").first { $0.label == "Utils" }?.kind == .module
                && items(rs + "RS.").first { $0.label == "Notify" }?.detail == "RemoteEvent")
        check("…and its methods after a colon", labels(rs + "RS:").contains("WaitForChild(name, timeout)"))
        check("inside require(, only what leads to a module", labels(rs + "require(RS.") == ["Shared", "Utils"], "\(labels(rs + "require(RS."))")
        check("into a folder", labels(rs + "require(RS.Shared.") == ["Config"])
        check("a remote reached by name has its own members", labels(rs + "RS.Notify:").contains("FireAllClients(...)"))
        check("WaitForChild(\" lists the names there", labels(rs + "RS:WaitForChild(\"") == ["Notify", "Shared", "Utils"],
              "\(labels(rs + "RS:WaitForChild(\""))")
        check("…closing the string and the call", insert("Utils", rs + "RS:WaitForChild(\"") == "Utils\")")
        check("…but not twice", LuauCompletion.items(in: rs + "RS:WaitForChild(\"\")", caret: (rs as NSString).length + 17, scene: scene)
                .first { $0.label == "Utils" }?.insert == "Utils")
        check("…narrowed as the name is typed", labels(rs + "RS:WaitForChild(\"Sh") == ["Shared"])
        check("…and only modules inside require(", labels(rs + "require(RS:WaitForChild(\"") == ["Shared", "Utils"])
        check("WaitForChild through to the next step", labels(rs + "RS:WaitForChild(\"Shared\").").first == "Config",
              "\(labels(rs + "RS:WaitForChild(\"Shared\")."))")
        check("workspace's Models and parts by name", labels("workspace.Tower.").prefix(1) == ["Door"],
              "\(labels("workspace.Tower."))")
        check("…a name with a space only in WaitForChild(\"", !labels("workspace.Tower.").contains("Left Arm")
                && labels("workspace.Tower:WaitForChild(\"Le") == ["Left Arm"])
        check("script.Parent is where the script is", labels("script.Parent.") == ["Enemy", "Main"], "\(labels("script.Parent."))")
        check("nothing in an ordinary string", labels("print(\"RS.").isEmpty)

        // What a required module hands back.
        let required1 = rs + "local Utils = require(RS.Utils)\n"
        check("a required module's functions and values", labels(required1 + "Utils.") ==
              ["clamp01(x)", "colours", "lerp(a, b, t)", "origin", "speed", "VERSION"], "\(labels(required1 + "Utils."))")
        check("…a function inserted ready for its arguments", insert("lerp(a, b, t)", required1 + "Utils.le") == "lerp(")
        check("…its methods after a colon", labels(required1 + "Utils:") == ["describe()"])
        check("…into a table it holds", labels(required1 + "Utils.colours.") == ["blue", "red"])
        check("…and through a value to its type", labels(required1 + "Utils.origin.").contains("Magnitude"))
        check("…the local is marked as a module", items(required1 + "Uti").first { $0.label == "Utils" }?.detail == "module")
        check("through WaitForChild too", labels(rs + "local U = require(RS:WaitForChild(\"Utils\"))\nU.l") == ["lerp(a, b, t)"])
        check("straight from require(…)", labels(rs + "require(RS.Shared.Config).") ==
              ["check(a)", "debug", "greet(name)", "maxPlayers", "spawn"], "\(labels(rs + "require(RS.Shared.Config)."))")
        let classes = "local Enemy = require(script.Parent.Enemy)\n"
        check("a class module offers its constructor", labels(classes + "Enemy.") == ["new(name, health)"],
              "\(labels(classes + "Enemy."))")
        let goblin = classes + "local goblin = Enemy.new(\"Goblin\", 50)\n"
        check("…and what it makes has the methods", labels(goblin + "goblin:") == ["Die()", "TakeDamage(amount)"],
              "\(labels(goblin + "goblin:"))")
        check("…and the fields", labels(goblin + "goblin.") == ["health", "name"], "\(labels(goblin + "goblin."))")

        // Built from a scene: a module in a part beside the script, one in a Folder in
        // ReplicatedStorage, one in ServerStorage.
        let built = SceneModel()
        if let door = built.parts.first {
            var logic = ScriptObject()
            logic.name = "DoorLogic"
            logic.kind = .module
            logic.parentID = door.id
            logic.source = "local M = {}\nfunction M.open(speed) end\nreturn M"
            var main = ScriptObject()
            main.name = "DoorScript"
            main.parentID = door.id
            let shared = DataObject(name: "Shared", className: .folder, parent: .replicatedStorage)
            var maths = ScriptObject()
            maths.name = "Maths"
            maths.kind = .module
            maths.host = .replicatedStorage
            maths.parentID = shared.id
            var secrets = ScriptObject()
            secrets.name = "Secrets"
            secrets.kind = .module
            secrets.host = .serverStorage
            built.scripts += [logic, main, maths, secrets]
            built.dataObjects.append(shared)
            let fromModel = built.luauScene(editing: main.id)
            let paths = Dictionary(uniqueKeysWithValues: LuauCompletion.items(in: "require(", caret: 8, scene: fromModel)
                .filter { $0.kind == .module }.map { ($0.label, $0.insert) })
            check("from the model: a module in the script's part, through script.Parent",
                  paths["DoorLogic"] == "script.Parent.DoorLogic)", "\(paths)")
            check("…one in a Folder in ReplicatedStorage", paths["Maths"] == "game:GetService(\"ReplicatedStorage\").Shared.Maths)")
            check("…and one in ServerStorage", paths["Secrets"] == "game:GetService(\"ServerStorage\").Secrets)")
            check("…and the part's module is read", LuauCompletion.items(in: "local L = require(script.Parent.DoorLogic)\nL.", caret: 45,
                                                                         scene: fromModel).map(\.label) == ["open(speed)"])
        }

        // The real thing: Adventure Island's modules, from its LocalScript.
        let model = SceneModel()
        model.loadAdventureIsland()
        if let adventure = model.scripts.first(where: { $0.name == "Adventure" }) {
            let island = model.luauScene(editing: adventure.id)
            let upTo = (adventure.source as NSString).range(of: "local Dialogue = require(").upperBound
            let source = (adventure.source as NSString).substring(to: upTo)
            let found = LuauCompletion.items(in: source, caret: (source as NSString).length, scene: island)
            check("Adventure Island: require( lists Dialogue and Zones", found.prefix(2).map(\.label) == ["Dialogue", "Zones"],
                  "\(found.prefix(4).map(\.label))")
            check("…through the script's own ReplicatedStorage local",
                  found.first?.insert == "ReplicatedStorage.Dialogue)", found.first?.insert ?? "-")
            let head = (adventure.source as NSString).substring(to: (adventure.source as NSString).range(of: "local Dialogue").location)
            let waiting = head + "local Notify = ReplicatedStorage:WaitForChild(\""
            let names = LuauCompletion.items(in: waiting, caret: (waiting as NSString).length, scene: island).map(\.label)
            check("…and WaitForChild(\" knows what ReplicatedStorage holds",
                  Set(names).isSuperset(of: ["Dialogue", "Zones", "Notify", "Quest"]), "\(names)")
        } else {
            check("Adventure Island has its LocalScript", false)
        }
    }

    private static func metalKinds(_ source: String) -> [(String, SyntaxTokenKind)] {
        let ns = source as NSString
        return MetalSyntax.tokenize(source).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private static func luauKinds(_ source: String) -> [(String, SyntaxTokenKind)] {
        let ns = source as NSString
        return LuauSyntax.tokenize(source).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private static func luauKind(_ text: String, in source: String) -> SyntaxTokenKind? {
        luauKinds(source).first { $0.0 == text }?.1
    }

    private static func testLuauLexer(_ check: Checker) {
        print("\nSyntax: Luau")
        check("local is a keyword", luauKind("local", in: "local x = 1") == .keyword)
        check("continue is a keyword", luauKind("continue", in: "continue") == .keyword)
        check("game is highlighted as a global", luauKind("game", in: "game:GetService('x')") == .type)
        check("Vector3 is a type", luauKind("Vector3", in: "Vector3.new()") == .type)
        check("a plain name is an identifier", luauKind("count", in: "local count = 1") == .identifier)

        check("-- starts a line comment", luauKind("-- note", in: "local a = 1 -- note\nlocal b") == .comment)
        let block = "local a = --[[ spans\nlines ]] 2"
        check("--[[ ]] is a block comment across lines",
              luauKinds(block).contains { $0.0 == "--[[ spans\nlines ]]" && $0.1 == .comment }, "\(luauKinds(block).map(\.0))")
        let levelled = "--[==[ has ]] inside ]==] x"
        check("long brackets match their level",
              luauKinds(levelled).first?.0 == "--[==[ has ]] inside ]==]", "\(luauKinds(levelled).map(\.0))")

        check("double quoted strings", luauKind("\"hi\"", in: "print(\"hi\")") == .string)
        check("single quoted strings", luauKind("'hi'", in: "print('hi')") == .string)
        check("long strings", luauKind("[[raw]]", in: "local s = [[raw]]") == .string)
        check("escapes are marked", luauKinds("print('a\\nb')").contains { $0.1 == .escape })

        let interpolated = luauKinds("print(`{count} parts`)")
        check("backtick interpolation braces are marked",
              interpolated.contains { $0.0 == "{" && $0.1 == .interpolation }, "\(interpolated.map(\.0))")
        check("code inside interpolation is lexed as code",
              interpolated.contains { $0.0 == "count" && $0.1 == .identifier })

        check("hex numbers", luauKind("0xFF", in: "local a = 0xFF") == .number)
        check("binary numbers", luauKind("0b1010", in: "local a = 0b1010") == .number)
        check("underscored numbers", luauKind("1_000_000", in: "local a = 1_000_000") == .number)
        check("decimals", luauKind("2.5", in: "local a = 2.5") == .number)
        check("a concatenation is not a decimal point",
              luauKinds("local s = 1 .. 'x'").contains { $0.0 == "1" && $0.1 == .number })

        check("an unterminated string stops at the line end",
              luauKind("x", in: "local s = 'open\nlocal x = 1") == .identifier)
        check("inside a comment is detected", LuauSyntax.isInCommentOrString(offset: 8, in: "-- talking here"))
        check("inside a string is detected", LuauSyntax.isInCommentOrString(offset: 12, in: "print(\"hello there\")"))
        check("just after a closed string is code again",
              !LuauSyntax.isInCommentOrString(offset: 9, in: "print('x')"))

        for (name, source) in [("Luau library", studioLibrarySource), ("Luau script template", ScriptObject.template)] {
            let tokens = LuauSyntax.tokenize(source)
            let length = (source as NSString).length
            check("\(name) tokenizes in bounds",
                  !tokens.isEmpty && tokens.allSatisfy { $0.range.location + $0.range.length <= length })
            check("\(name) has no string swallowing the file",
                  tokens.filter { $0.kind == .string }.allSatisfy { $0.range.length < length / 4 })
        }
    }

    private static func luauLabels(_ source: String) -> [String] {
        LuauCompletion.items(in: source, caret: (source as NSString).length).map(\.label)
    }

    private static func testLuauCompletion(_ check: Checker) {
        print("\nCompletion: Luau")
        let service = luauLabels("local RunService = game:GetService(\"RunService\")\nRunService.")
        check("GetService resolves by its string argument", service.contains("Heartbeat"), "\(service)")

        let chain = luauLabels("game:GetService(\"RunService\").Heartbeat:")
        check("a signal offers Connect after a colon", chain.contains("Connect(callback)"), "\(chain)")

        let props = luauLabels("workspace.Brick.")
        check("a dot offers properties", props.contains("Position") && props.contains("Anchored"), "\(props)")
        check("…but not methods", !props.contains("Destroy()"), "\(props)")

        let methods = luauLabels("workspace.Brick:")
        check("a colon offers methods", methods.contains("Destroy()") && methods.contains("Clone()"), "\(methods)")
        check("…but not properties", !methods.contains("Position"), "\(methods)")

        let found = luauLabels("local orb = workspace:FindFirstChild(\"Orb\")\norb.Pos")
        check("a local takes the type of what it was assigned", found == ["Position"], "\(found)")

        let annotated = luauLabels("local v: Vector3 = something()\nv.")
        check("a type annotation is honoured", annotated.contains("Magnitude"), "\(annotated)")

        let vector = luauLabels("Vector3.new(1, 2, 3).")
        check("a constructed value is an instance", vector.contains("Unit") && !vector.contains("new(x, y, z)"),
              "\(vector)")

        let statics = luauLabels("Vector3.")
        check("a namespace offers its statics", statics.contains("new(x, y, z)") && statics.contains("zero"), "\(statics)")

        let enums = luauLabels("Enum.Material.")
        check("enum namespaces list their items", enums.contains("Neon"), "\(enums)")

        let math = luauLabels("math.l")
        check("math offers Luau's and Studio's functions",
              math.contains("lerp(a, b, t)") && math.contains("log(x, base)"), "\(math)")

        let humanoid = luauLabels("local humanoid = game:GetService(\"Players\").LocalPlayer.Character:WaitForChild(\"Humanoid\")\nhumanoid.")
        check("a character's Humanoid offers its properties",
              humanoid.contains("WalkSpeed") && humanoid.contains("JumpPower") && humanoid.contains("Died"), "\(humanoid)")
        let humanoidMethods = luauLabels("Players.LocalPlayer.Character.Humanoid:")
        check("…and its methods", humanoidMethods.contains("Move(direction, relativeToCamera)")
              && humanoidMethods.contains("TakeDamage(amount)"), "\(humanoidMethods)")
        let input = luauLabels("game:GetService(\"UserInputService\"):")
        check("UserInputService is known", input.contains("IsKeyDown(keyCode)"), "\(input)")
        let keys = luauLabels("Enum.KeyCode.")
        check("Enum.KeyCode lists keys", keys.contains("Space") && keys.contains("LeftShift") && keys.contains("W"), "\(keys.count)")
        let states = luauLabels("Enum.HumanoidStateType.")
        check("Enum.HumanoidStateType lists states", states.contains("Freefall"), "\(states)")
        let torso = luauLabels("Players.LocalPlayer.Character.Torso.")
        check("body parts offer Color", torso.contains("Color") && torso.contains("Transparency"), "\(torso)")

        let touch = luauLabels("workspace.Brick.")
        check("parts offer Touched, TouchEnded, CanCollide and CanTouch",
              touch.contains("Touched") && touch.contains("TouchEnded") && touch.contains("CanCollide")
              && touch.contains("CanTouch"), "\(touch)")
        let touchedWith = luauLabels("workspace.Brick.Touched:")
        check("…and Touched is a signal", touchedWith.contains("Connect(callback)"), "\(touchedWith)")
        let fromCharacter = luauLabels("game:GetService(\"Players\"):")
        check("Players offers GetPlayerFromCharacter",
              fromCharacter.contains("GetPlayerFromCharacter(character)"), "\(fromCharacter)")

        let hinge = luauLabels("local hinge = Instance.new(\"HingeConstraint\")\nhinge.")
        check("completion knows joints",
              hinge.contains("AngularVelocity") && hinge.contains("Attachment0") && hinge.contains("CurrentAngle"),
              "\(hinge)")
        let actuator = luauLabels("Enum.ActuatorType.")
        check("…and Enum.ActuatorType", actuator.contains("Servo"), "\(actuator)")

        let parent = luauLabels("script.Parent.")
        check("script.Parent is a Part", parent.contains("Position"), "\(parent)")

        let either = luauLabels("local part = script.Parent or workspace:FindFirstChild(\"Orb\")\npart.")
        check("`a or b` takes the first choice's type", either.contains("Position"), "\(either)")

        let locals = luauLabels("local tower = workspace.Tower\nlocal function spin(speed)\n  tow")
        check("locals are offered at the top level", locals.contains("tower"), "\(locals)")
        let params = luauLabels("local function spin(speed, axis)\n  spe")
        check("function parameters are offered", params.contains("speed"), "\(params)")

        check("nothing is offered inside a comment", LuauCompletion.items(in: "-- workspace.", caret: 13).isEmpty)
        check("nothing is offered inside a string", LuauCompletion.items(in: "print('workspace.", caret: 17).isEmpty)
        check("concatenation is not member access", LuauCompletion.items(in: "local s = a ..", caret: 14).isEmpty)
        check("an unknown receiver offers nothing", LuauCompletion.items(in: "mystery.", caret: 8).isEmpty)

        // The order: the case typed first, then the script's own locals, keywords, globals.
        let order: [(String, String)] = [
            ("en", "end"), ("En", "Enum"), ("sc", "script"), ("wo", "workspace"), ("an", "and"), ("Co", "Color3"),
            ("local part = workspace.Part\npa", "part"), ("local count = 0\nco", "count"), ("re", "repeat"),
        ]
        for (source, first) in order {
            let labels = luauLabels(source)
            check("\(source.replacingOccurrences(of: "\n", with: " ⏎ ")) → \(first) first", labels.first == first, "\(labels)")
        }
        check("a name is listed once even when a local shadows a global",
              luauLabels("local workspace = 1\nwork").filter { $0 == "workspace" }.count == 1)
        for source in ["local pl", "local a, bo", "local x: Pa", "local function onTo", "function onTouched(hi",
                       "function Module.new(na", "local handler = function(pa", "for i", "for _, pl", "\tlocal nam"] {
            check("nothing while naming: \(source)", luauLabels(source).isEmpty, "\(luauLabels(source))")
        }
        for (source, wanted) in [("local x = pa", "pairs(t)"), ("for _, v in ip", "ipairs(t)"), ("for i = 1, ma", "math"),
                                 ("local function f()\n\tretu", "return"), ("myfunction = pr", "print(...)")] {
            check("…but the value is suggested: \(source)", luauLabels(source).first == wanted, "\(luauLabels(source))")
        }

        let top = luauLabels("wor")
        check("globals are offered at the top level", top.contains("workspace"), "\(top)")
    }

    private static func testMetalLexer(_ check: Checker) {
        print("\nSyntax: Metal")
        let source = """
        // rim light
        float3 tint = baseColor * 2.0f;
        float rim = pow(1.0 - facing, 2.5);
        return tint;
        """
        let tokens = metalKinds(source)
        check("float3 is a type", tokens.contains { $0.0 == "float3" && $0.1 == .type })
        check("return is a keyword", tokens.contains { $0.0 == "return" && $0.1 == .keyword })
        check("a suffixed literal is one number", tokens.contains { $0.0 == "2.0f" && $0.1 == .number })
        check("a decimal is a number", tokens.contains { $0.0 == "2.5" && $0.1 == .number })
        check("comments are comments", tokens.contains { $0.0 == "// rim light" && $0.1 == .comment })
        check("an ordinary name is an identifier",
              tokens.contains { $0.0 == "tint" && $0.1 == .identifier })

        // Unlike Wren, C++ block comments do not nest — the first */ ends them.
        let nested = metalKinds("/* a /* b */ c")
        check("block comments do not nest",
              nested.contains { $0.0 == "/* a /* b */" && $0.1 == .comment }, "\(nested.map(\.0))")

        check("a preprocessor line is marked",
              metalKinds("#include <metal_stdlib>").contains { $0.1 == .attribute })
        check("ranges stay in bounds", MetalSyntax.tokenize(source).allSatisfy {
            $0.range.location + $0.range.length <= (source as NSString).length
        })
        check("the shipped example tokenizes", !MetalSyntax.tokenize(ShaderObject.pulseExample).isEmpty)

        // codeOnly is what the empty-body check relies on.
        check("comments are stripped for validation",
              MetalSyntax.codeOnly("// only a comment").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        check("code survives stripping",
              MetalSyntax.codeOnly("return a; // note").contains("return a;"))
    }

    private static func testMetalCompletion(_ check: Checker) {
        print("\nCompletion: Metal")
        let params = ["speed", "glow"]
        let atEnd = { (source: String) in
            MetalCompletion.items(in: source, caret: (source as NSString).length,
                                  parameters: params).map(\.label)
        }

        let inputs = atEnd("return nor")
        check("injected inputs are offered", inputs.contains("normal"), "\(inputs)")

        let parameters = atEnd("return baseColor * sp")
        check("the shader's own parameters are offered",
              parameters.contains("speed"), "\(parameters)")

        let functions = atEnd("float a = smoo")
        check("built-in functions are offered", functions.contains("smoothstep()"), "\(functions)")
        let insert = MetalCompletion.items(in: "float a = smoo", caret: 14, parameters: params).first
        check("a function inserts an opening paren", insert?.insert == "smoothstep(",
              "\(String(describing: insert?.insert))")

        let types = atEnd("float")
        check("types are offered", types.contains("float3"), "\(types)")

        let swizzle = atEnd("float a = normal.")
        check("components are offered after a dot", swizzle.contains("xyz"), "\(swizzle)")
        check("functions are not offered after a dot", !swizzle.contains("sin()"), "\(swizzle)")

        check("nothing is offered inside a comment",
              MetalCompletion.items(in: "// normal talk", caret: 12, parameters: params).isEmpty)
    }

    // MARK: - Helpers

    private static func kinds(_ source: String) -> [(String, SyntaxTokenKind)] {
        let ns = source as NSString
        return WrenSyntax.tokenize(source).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private static func kind(of text: String, in source: String) -> SyntaxTokenKind? {
        kinds(source).first { $0.0 == text }?.1
    }

    private static func labels(_ source: String, caret: Int) -> [String] {
        WrenCompletion.items(in: source, caret: caret).map(\.label)
    }

    /// Completions with the caret at the end of the source.
    private static func labelsAtEnd(_ source: String) -> [String] {
        labels(source, caret: (source as NSString).length)
    }

    // MARK: - Lexer

    private static func testTokenRanges(_ check: Checker) {
        print("\nSyntax: token ranges")
        let source = "var a = 1 + 2 // note\nclass Foo {}\n"
        let tokens = WrenSyntax.tokenize(source)
        let length = (source as NSString).length

        check("produces tokens", !tokens.isEmpty)
        check("every range is inside the text",
              tokens.allSatisfy { $0.range.location >= 0 && $0.range.location + $0.range.length <= length })
        check("no empty ranges", tokens.allSatisfy { $0.range.length > 0 })
        check("ranges do not overlap and are ordered", zip(tokens, tokens.dropFirst()).allSatisfy {
            $0.range.location + $0.range.length <= $1.range.location
        })
        check("an empty document yields nothing", WrenSyntax.tokenize("").isEmpty)
    }

    private static func testKeywordsAndTypes(_ check: Checker) {
        print("\nSyntax: words")
        let source = "class Tower is Object { construct new(size) { _size = size } }\nvar count = 2\n__shared = 1\n"
        check("class is a keyword", kind(of: "class", in: source) == .keyword)
        check("construct is a keyword", kind(of: "construct", in: source) == .keyword)
        check("is is a keyword", kind(of: "is", in: source) == .keyword)
        check("var is a keyword", kind(of: "var", in: source) == .keyword)
        check("a capitalised name is a type", kind(of: "Tower", in: source) == .type)
        check("Object is a type", kind(of: "Object", in: source) == .type)
        check("a lowercase name is an identifier", kind(of: "count", in: source) == .identifier)
        check("an instance field is a field", kind(of: "_size", in: source) == .field)
        check("a static field is a field", kind(of: "__shared", in: source) == .field)
        check("a keyword inside a longer word is not a keyword",
              kind(of: "classroom", in: "var classroom = 1") == .identifier)
    }

    private static func testComments(_ check: Checker) {
        print("\nSyntax: comments")
        check("line comments run to the end of the line",
              kind(of: "// trailing", in: "var a = 1 // trailing\nvar b = 2") == .comment)
        let block = "var a = /* one /* nested */ still */ 2"
        let comment = kinds(block).first { $0.1 == .comment }?.0
        check("block comments nest", comment == "/* one /* nested */ still */", comment ?? "none")
        check("an unterminated block comment does not hang",
              kinds("var a = /* never closed").contains { $0.1 == .comment })
        check("a comment does not swallow the next line",
              kind(of: "b", in: "// note\nvar b = 1") == .identifier)
    }

    private static func testStrings(_ check: Checker) {
        print("\nSyntax: strings")
        let simple = "var name = \"Orb\""
        check("a string is one token", kind(of: "\"Orb\"", in: simple) == .string)

        let escaped = "var s = \"a\\nb\""
        check("escapes are marked separately", kinds(escaped).contains { $0.1 == .escape })

        let interpolated = "Runtime.log(\"y=%(part.position.y) done\")"
        let tokens = kinds(interpolated)
        check("interpolation delimiters are marked",
              tokens.contains { $0.0 == "%(" && $0.1 == .interpolation })
        check("the closing paren of an interpolation is marked",
              tokens.contains { $0.0 == ")" && $0.1 == .interpolation })
        check("code inside an interpolation is lexed as code",
              tokens.contains { $0.0 == "part" && $0.1 == .identifier })
        check("text around the interpolation stays a string",
              tokens.contains { $0.0 == "\"y=" && $0.1 == .string })

        check("nested parens inside an interpolation balance",
              kinds("\"%((1 + 2).abs) end\"").contains { $0.0 == "abs" && $0.1 == .identifier })
        check("an unterminated string does not hang",
              kinds("var s = \"open").contains { $0.1 == .string })
    }

    private static func testNumbers(_ check: Checker) {
        print("\nSyntax: numbers")
        check("integers", kind(of: "42", in: "var a = 42") == .number)
        check("decimals", kind(of: "3.5", in: "var a = 3.5") == .number)
        check("hex", kind(of: "0xff", in: "var a = 0xff") == .number)
        check("exponents", kind(of: "1e-3", in: "var a = 1e-3") == .number)
        // `1.abs` is a method call on a number, not the decimal `1.`
        let method = kinds("var a = 1.abs")
        check("a trailing dot is not part of the number",
              method.contains { $0.0 == "1" && $0.1 == .number }, "\(method.map(\.0))")
    }

    private static func testCommentAndStringDetection(_ check: Checker) {
        print("\nSyntax: caret context")
        let source = "var a = 1 // writing a note here\nvar b = \"text\"\n"
        check("inside a comment is detected",
              WrenSyntax.isInCommentOrString(offset: 20, in: source))
        check("inside a string is detected",
              WrenSyntax.isInCommentOrString(offset: 45, in: source))
        check("ordinary code is not",
              !WrenSyntax.isInCommentOrString(offset: 4, in: source))
    }

    // MARK: - Completion

    private static func testPartialWord(_ check: Checker) {
        print("\nCompletion: partial word")
        let source = "var part = Workspace.fin"
        let range = WrenCompletion.partialWordRange(in: source, caret: (source as NSString).length)
        check("the partial word is the identifier before the caret",
              (source as NSString).substring(with: range) == "fin",
              (source as NSString).substring(with: range))

        let afterDot = "part."
        let empty = WrenCompletion.partialWordRange(in: afterDot, caret: 5)
        check("the range is empty right after a dot", empty.length == 0 && empty.location == 5,
              "\(empty)")
    }

    private static func testStaticMembers(_ check: Checker) {
        print("\nCompletion: class members")
        let workspace = labelsAtEnd("import \"studio\" for Workspace\nWorkspace.")
        check("Workspace offers find", workspace.contains("find(name)"), "\(workspace)")
        check("Workspace offers create", workspace.contains { $0.hasPrefix("create(") }, "\(workspace)")
        check("Workspace offers parts", workspace.contains("parts"))
        check("Workspace does not offer Part members", !workspace.contains("anchored"))

        let filtered = labelsAtEnd("Workspace.fin")
        check("a prefix filters the list", filtered == ["find(name)", "findAll(name)"], "\(filtered)")

        let vec = labelsAtEnd("Vec3.")
        check("Vec3 offers its constructor", vec.contains("new(x, y, z)"), "\(vec)")
        check("Vec3 offers zero", vec.contains("zero"))

        let runtime = labelsAtEnd("Runtime.")
        check("Runtime offers onUpdate", runtime.contains("onUpdate(fn)"), "\(runtime)")
        check("Runtime offers time", runtime.contains("time"))

        let onUpdate = WrenCompletion.items(in: "Runtime.on", caret: 10).first
        check("a method taking a block inserts without a paren",
              onUpdate?.insert == "onUpdate ", "\(String(describing: onUpdate?.insert))")
        let find = WrenCompletion.items(in: "Workspace.find", caret: 14).first
        check("an ordinary method inserts an opening paren",
              find?.insert == "find(", "\(String(describing: find?.insert))")
        check("a method carries its return type as the hint",
              find?.detail == "Part", "\(String(describing: find?.detail))")
    }

    private static func testInferredLocals(_ check: Checker) {
        print("\nCompletion: inferred variables")
        let source = """
        import "studio" for Workspace, Vec3
        var orb = Workspace.find("Orb")
        orb.
        """
        let members = labelsAtEnd(source)
        check("a variable takes the type of what it was assigned",
              members.contains("position") && members.contains("destroy()"), "\(members)")
        check("and offers only that type's members", !members.contains("find(name)"))

        let vector = labelsAtEnd("var v = Vec3.new(1, 2, 3)\nv.")
        check("a constructed value is an instance",
              vector.contains("normalized") && vector.contains("cross(other)"), "\(vector)")
        check("an instance does not offer the class constructor", !vector.contains("new(x, y, z)"))

        let scriptParent = labelsAtEnd("script.parent.")
        check("script.parent resolves to a Part",
              scriptParent.contains("anchored"), "\(scriptParent)")

        let number = labelsAtEnd("var t = 3.5\nt.")
        check("a numeric literal infers Num", number.contains("sqrt"), "\(number)")

        let text = labelsAtEnd("var s = \"hello\"\ns.")
        check("a string literal infers String", text.contains("startsWith(text)"), "\(text)")

        let shadowed = labelsAtEnd("var Workspace = \"not the class\"\nWorkspace.")
        check("a local shadows a class of the same name",
              shadowed.contains("startsWith(text)") && !shadowed.contains("find(name)"), "\(shadowed)")

        let circular = labelsAtEnd("var a = a.b\na.")
        check("a self-referential variable does not hang", circular.isEmpty, "\(circular)")
    }

    private static func testChains(_ check: Checker) {
        print("\nCompletion: chained expressions")
        let chained = labelsAtEnd("Workspace.find(\"Orb\").position.")
        check("a chain follows return types through a call",
              chained.contains("normalized") && chained.contains("x"), "\(chained)")

        let deeper = labelsAtEnd("Workspace.find(\"Orb\").position.x.")
        check("a chain keeps going", deeper.contains("sqrt"), "\(deeper)")

        let colour = labelsAtEnd("script.parent.color.")
        check("a chain through script.parent works", colour.contains("lerp(other, t)"), "\(colour)")

        let list = labelsAtEnd("Workspace.parts.")
        check("a list of parts offers list members", list.contains("count"), "\(list)")

        let element = labelsAtEnd("Workspace.parts[0].")
        check("subscripting a list gives the element type",
              element.contains("anchored"), "\(element)")

        let nestedCall = labelsAtEnd("Workspace.create(\"block\", Vec3.new(0, 1, 0)).")
        check("nested parentheses do not confuse the parser",
              nestedCall.contains("destroy()"), "\(nestedCall)")

        let literalMethod = labelsAtEnd("(1 + 2).abs.")
        check("an unresolvable receiver offers nothing rather than nonsense",
              literalMethod.isEmpty || literalMethod.contains("sqrt"), "\(literalMethod)")
    }

    private static func testGlobalCompletion(_ check: Checker) {
        print("\nCompletion: top level")
        let all = labelsAtEnd("Wor")
        check("known classes are offered", all.contains("Workspace"), "\(all)")

        let keywords = labelsAtEnd("cl")
        check("keywords are offered", keywords.contains("class"), "\(keywords)")

        let documented = labelsAtEnd("var tower = Workspace.find(\"Tower\")\nvar t2 = 1\ntow")
        check("variables declared in the document are offered",
              documented.contains("tower"), "\(documented)")

        let typed = WrenCompletion.items(in: "var tower = Workspace.find(\"Tower\")\ntow", caret: 39)
        check("a declared variable shows its inferred type",
              typed.first { $0.label == "tower" }?.detail == "Part",
              "\(String(describing: typed.first { $0.label == "tower" }?.detail))")

        let blockParam = labelsAtEnd("Runtime.onUpdate { |delta|\n  del")
        check("block parameters are offered", blockParam.contains("delta"), "\(blockParam)")

        let classes = labelsAtEnd("class Spinner {}\nSpin")
        check("classes declared in the document are offered",
              classes.contains("Spinner"), "\(classes)")

        let math = labelsAtEnd("import \"math\" for Math\nMath.")
        check("Math offers its helpers",
              math.contains("lerp(a, b, t)") && math.contains("smoothstep(edge0, edge1, value)"),
              "\(math)")
        check("Math offers its constants", math.contains("pi"), "\(math)")

        let ease = labelsAtEnd("Ease.out")
        check("Ease offers its curves", ease.contains("outCubic(t)"), "\(ease)")

        let rand = labelsAtEnd("Rand.")
        check("Rand offers its generators",
              rand.contains("int(high)") && rand.contains("direction"), "\(rand)")

        let noise = labelsAtEnd("Noise.")
        check("Noise offers its fields", noise.contains("fbm(x, y)"), "\(noise)")

        let mathTypes = labelsAtEnd("Noi")
        check("math classes are offered at the top level",
              mathTypes.contains("Noise"), "\(mathTypes)")

        // Return types chain through the math module too.
        let chained = labelsAtEnd("Rand.direction.")
        check("a random direction is known to be a Vec3",
              chained.contains("normalized") && chained.contains("rotatedY(degrees)"), "\(chained)")

        let vectorExtras = labelsAtEnd("import \"studio\" for Vec3\nVec3.new(1,2,3).")
        check("the new vector helpers are offered",
              vectorExtras.contains("reflect(normal)") && vectorExtras.contains("distanceTo(other)"),
              "\(vectorExtras)")

        check("a import snippet is offered",
              labelsAtEnd("imp").contains { $0.hasPrefix("import") }, "\(labelsAtEnd("imp"))")
    }

    private static func testCompletionRestraint(_ check: Checker) {
        print("\nCompletion: staying out of the way")
        check("no completions inside a comment",
              WrenCompletion.items(in: "// talking about Workspace here", caret: 30).isEmpty)
        check("no completions inside a string",
              WrenCompletion.items(in: "var s = \"Workspace\"", caret: 17).isEmpty)
        check("no members for an unknown receiver",
              WrenCompletion.items(in: "mysteryThing.", caret: 13).isEmpty)
        check("no members for a typo'd class",
              WrenCompletion.items(in: "Workspac.", caret: 9).isEmpty)

        let interpolated = labelsAtEnd("Runtime.log(\"%(script.parent.")
        check("completion still works inside a string interpolation",
              interpolated.contains("position"), "\(interpolated)")

        let many = WrenCompletion.items(in: "", caret: 0)
        check("an empty document still offers something", !many.isEmpty)
        check("the list is capped", many.count <= 60, "\(many.count)")
    }

    private static func testShippedSourcesTokenize(_ check: Checker) {
        print("\nSyntax: shipped sources")
        // The studio module and the script template are the largest Wren we ship.
        for (name, source) in [("Wren studio module", wrenStudioModuleSource),
                               ("Wren script template", ScriptObject.wrenTemplate)] {
            let tokens = WrenSyntax.tokenize(source)
            let length = (source as NSString).length
            check("\(name) tokenizes", !tokens.isEmpty)
            check("\(name) ranges stay in bounds",
                  tokens.allSatisfy { $0.range.location + $0.range.length <= length })
            check("\(name) has no unterminated string swallowing the file",
                  tokens.filter { $0.kind == .string }.allSatisfy { $0.range.length < length / 2 })
        }
    }
}
