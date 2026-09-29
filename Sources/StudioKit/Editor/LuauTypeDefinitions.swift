import Foundation

/// Typed properties and return values share the completion catalog. Explicit method
/// signatures supply the argument types that a display-only completion cannot express.
/// Real Luau built-ins remain registered by the official Frontend.
enum LuauTypeDefinitions {
    private static let values: Set<String> = ["Vector3", "Vector2", "Color3", "CFrame", "UDim", "UDim2", "Ray", "Region3", "Random", "NumberRange", "NumberSequence", "NumberSequenceKeypoint", "ColorSequence", "ColorSequenceKeypoint", "TweenInfo", "RaycastParams", "RaycastResult", "EnumItem", "InputObject", "RBXScriptSignal", "RBXScriptConnection", "Path", "PathWaypoint", "DataStore", "OrderedDataStore", "DataStorePages", "Tween", "Shader"]
    static let signatures: [String: String] = [
        "Vector3.new": "(x: number?, y: number?, z: number?) -> Vector3",
        "Vector2.new": "(x: number?, y: number?) -> Vector2",
        "Color3.new": "(r: number?, g: number?, b: number?) -> Color3",
        "Color3.fromRGB": "(r: number, g: number, b: number) -> Color3",
        "Color3.fromHSV": "(h: number, s: number, v: number) -> Color3",
        "Color3.fromHex": "(hex: string) -> Color3",
        "UDim.new": "(scale: number?, offset: number?) -> UDim",
        "UDim2.new": "(xScale: number?, xOffset: number?, yScale: number?, yOffset: number?) -> UDim2",
        "UDim2.fromScale": "(x: number, y: number) -> UDim2",
        "UDim2.fromOffset": "(x: number, y: number) -> UDim2",
        "Ray.new": "(origin: Vector3, direction: Vector3) -> Ray",
        "Region3.new": "(minimum: Vector3, maximum: Vector3) -> Region3",
        "NumberRange.new": "(minimum: number, maximum: number?) -> NumberRange",
        "NumberSequence.new": "((value: number, finish: number?) -> NumberSequence) & ((keys: {NumberSequenceKeypoint}) -> NumberSequence)",
        "ColorSequence.new": "((value: Color3, finish: Color3?) -> ColorSequence) & ((keys: {ColorSequenceKeypoint}) -> ColorSequence)",
        "NumberSequenceKeypoint.new": "(time: number, value: number, envelope: number?) -> NumberSequenceKeypoint",
        "ColorSequenceKeypoint.new": "(time: number, value: Color3) -> ColorSequenceKeypoint",
        "Random.new": "(seed: number?) -> Random",
        "TweenInfo.new": "(time: number?, style: EnumItem?, direction: EnumItem?, repeatCount: number?, reverses: boolean?, delayTime: number?) -> TweenInfo",
        "task.wait": "(seconds: number?) -> number",
        "task.spawn": "(callback: ((...any) -> ...any) | thread, ...any) -> thread",
        "task.defer": "(callback: ((...any) -> ...any) | thread, ...any) -> thread",
        "task.delay": "(seconds: number, callback: ((...any) -> ...any) | thread, ...any) -> thread",
        "task.cancel": "(thread: thread) -> ()",
        "RBXScriptSignal.Connect": "(self: RBXScriptSignal, callback: (...any) -> ()) -> RBXScriptConnection",
        "RBXScriptSignal.Once": "(self: RBXScriptSignal, callback: (...any) -> ()) -> RBXScriptConnection",
        "RBXScriptSignal.Wait": "(self: RBXScriptSignal) -> ...any",
        "Workspace.Raycast": "(self: Workspace, origin: Vector3, direction: Vector3, params: RaycastParams?) -> RaycastResult?",
        "TweenService.Create": "(self: TweenService, object: Instance, info: TweenInfo, goals: {[string]: any}) -> Tween",
        "Humanoid.TakeDamage": "(self: Humanoid, damage: number) -> ()",
        "Humanoid.MoveTo": "(self: Humanoid, point: Vector3, part: Part?) -> ()",
        "Humanoid.Move": "(self: Humanoid, direction: Vector3, relativeToCamera: boolean?) -> ()",
        "Model.PivotTo": "(self: Model, frame: CFrame) -> ()",
        "Part.PivotTo": "(self: Part, frame: CFrame) -> ()",
        "Player.Teleport": "(self: Player, position: Vector3) -> ()",
        "Part.UnionAsync": "(self: BasePart, parts: {BasePart}, collisionFidelity: EnumItem?) -> UnionOperation",
        "Part.SubtractAsync": "(self: BasePart, parts: {BasePart}, collisionFidelity: EnumItem?) -> UnionOperation",
        "Mouse.GetUnitRay": "(self: Mouse) -> Ray"
    ]

    private static func name(_ item: CompletionItem) -> String { String(item.label.prefix { $0 != "(" }) }
    private static func type(_ value: String) -> String {
        switch value {
        case "table": return "{[any]: any}"
        case "function": return "(...any) -> ...any"
        case "...": return "...any"
        case "iterator": return "any"
        default: return value.hasPrefix("Enum.") ? "Enum_" + value.dropFirst(5) : value
        }
    }
    private static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r") + "\""
    }
    private static func argumentType(_ argument: String) -> String {
        if ["name", "className", "property", "key", "text", "message", "reference", "soundId", "assetId", "hex"].contains(argument) { return "string" }
        if ["seconds", "time", "duration", "speed", "volume", "count", "alpha", "weight", "fadeTime", "damage", "radius", "resolution", "x", "y", "z", "t", "min", "max", "seed", "distance", "timeout", "length", "degrees", "step"].contains(argument) { return "number?" }
        if ["position", "direction", "origin", "point", "vector", "goal", "start", "finish"].contains(argument) { return "Vector3" }
        if argument == "player" { return "Player" }
        if argument == "callback" || argument == "transform" { return "(...any) -> ...any" }
        return "any"
    }
    private static func member(_ item: CompletionItem, owner: String, instance: Bool) -> String {
        let label = name(item)
        if item.kind != .method {
            var value = type(item.returns ?? item.detail)
            if label == "Parent" { value = "Instance?" }
            if value == "RBXScriptSignal" {
                let payloads: [String: String] = ["Touched": "Part", "TouchEnded": "Part", "PlayerAdded": "Player", "PlayerRemoving": "Player", "CharacterAdded": "Model", "CharacterRemoving": "Model", "Heartbeat": "number", "RenderStepped": "number", "Stepped": "number, number", "HealthChanged": "number", "Running": "number", "MoveToFinished": "boolean", "InputBegan": "InputObject, boolean", "InputEnded": "InputObject, boolean", "InputChanged": "InputObject, boolean", "MouseClick": "Player", "RightMouseClick": "Player", "MouseHoverEnter": "Player", "MouseHoverLeave": "Player"]
                if let payload = payloads[label] { value = "StudioSignal<\(payload)>" }
            }
            if owner == "Mouse" && (label == "Target" || label == "TargetFilter") { value = "Instance?" }
            if owner == "ViewportFrame" && label == "CurrentCamera" { value = "Camera?" }
            if ["SurfaceGui", "BillboardGui"].contains(owner) && label == "Adornee" { value = "BasePart?" }
            if owner == "IntValue" || owner == "NumberValue", label == "Value" { value = "number" }
            if owner == "StringValue", label == "Value" { value = "string" }
            if owner == "BoolValue", label == "Value" { value = "boolean" }
            if owner == "Vector3Value", label == "Value" { value = "Vector3" }
            if owner == "Color3Value", label == "Value" { value = "Color3" }
            if owner == "CFrameValue", label == "Value" { value = "CFrame" }
            if owner == "ObjectValue", label == "Value" { value = "Instance?" }
            return "\(label): \(value)"
        }
        if ["UnionAsync", "SubtractAsync"].contains(label), let signature = signatures["Part." + label] { return "\(label): \(signature)" }
        if let signature = signatures[owner + "." + label] { return "\(label): \(signature)" }
        var arguments = instance ? ["self: \(owner)"] : []
        if let begin = item.label.firstIndex(of: "("), let end = item.label.lastIndex(of: ")") {
            for (index, argument) in item.label[item.label.index(after: begin)..<end].split(separator: ",").enumerated() {
                let argument = argument.trimmingCharacters(in: .whitespaces)
                if argument == "..." { arguments.append("...any") }
                else { arguments.append("a\(index): \(argumentType(argument))") }
            }
        }
        var returns = type(item.returns ?? "()")
        if label == "FindFirstChild" || label == "WaitForChild" || label == "FindFirstChildOfClass" { returns = "any" }
        if label == "GetChildren" || label == "GetDescendants" { returns = "{Instance}" }
        if label == "Clone" { returns = owner }
        return "\(label): (\(arguments.joined(separator: ", "))) -> \(returns)"
    }

    static func source(scene: LuauScene) -> String {
        var catalog = LuauAPI.instanceMembers
        catalog["CFrame"] = []
        for name in ["Instance", "BasePart", "UnionOperation", "Camera", "LocalScript"] where catalog[name] == nil { catalog[name] = [] }
        var known = Set(catalog.keys)
        for members in catalog.values {
            for item in members {
                let value = type(item.returns ?? "")
                if value.first?.isUppercase == true && !value.contains(".") { known.insert(value) }
            }
        }
        for name in known where catalog[name] == nil { catalog[name] = [] }
        let base = """
        declare class Instance
            Name: string
            ClassName: string
            Parent: Instance?
            Destroy: (self: Instance) -> ()
            Clone: (self: Instance) -> Instance
            IsA: (self: Instance, className: string) -> boolean
            FindFirstChild: (self: Instance, name: string, recursive: boolean?) -> any
            WaitForChild: (self: Instance, name: string, timeout: number?) -> any
            FindFirstChildOfClass: (self: Instance, className: string) -> any
            GetChildren: (self: Instance) -> {Instance}
            GetDescendants: (self: Instance) -> {Instance}
            GetFullName: (self: Instance) -> string
            GetPropertyChangedSignal: (self: Instance, name: string) -> RBXScriptSignal
        end
        """
        let inherited: Set<String> = ["Name", "ClassName", "Parent", "Destroy", "IsA", "FindFirstChild", "WaitForChild", "FindFirstChildOfClass", "GetChildren", "GetDescendants", "GetFullName", "GetPropertyChangedSignal"]
        var declarations = [base, """
        type StudioSignal<T...> = {
            Connect: (self: StudioSignal<T...>, callback: (T...) -> ()) -> RBXScriptConnection,
            Once: (self: StudioSignal<T...>, callback: (T...) -> ()) -> RBXScriptConnection,
            Wait: (self: StudioSignal<T...>) -> T...
        }
        """]
        let parents: [String: String] = ["Part": "BasePart", "MeshPart": "BasePart", "PartOperation": "BasePart", "UnionOperation": "PartOperation", "NegateOperation": "PartOperation", "BodyPart": "BasePart", "HumanoidRootPart": "BasePart", "PointLight": "Light", "SpotLight": "Light", "SurfaceLight": "Light", "LocalScript": "Script"]
        var remaining = Set(catalog.keys).subtracting(["Instance"]), owners: [String] = []
        var declared: Set<String> = ["Instance"]
        while !remaining.isEmpty {
            let ready = remaining.filter { declared.contains(parents[$0] ?? "Instance") }.sorted()
            guard !ready.isEmpty else { break }
            owners += ready
            declared.formUnion(ready); remaining.subtract(ready)
        }
        for owner in owners {
            let isValue = values.contains(owner)
            let parent = parents[owner] ?? "Instance"
            var members = catalog[owner]!.filter { isValue || !inherited.contains(name($0)) }.map { member($0, owner: owner, instance: true) }
            if ["Vector3", "Vector2"].contains(owner) {
                members += ["__add: (\(owner), \(owner)) -> \(owner)", "__sub: (\(owner), \(owner)) -> \(owner)", "__mul: ((\(owner), number) -> \(owner)) & ((\(owner), \(owner)) -> \(owner))", "__div: (\(owner), number) -> \(owner)", "__unm: (\(owner)) -> \(owner)"]
            }
            if owner == "CFrame" {
                members += ["Position: Vector3", "LookVector: Vector3", "RightVector: Vector3", "UpVector: Vector3", "X: number", "Y: number", "Z: number", "__mul: ((CFrame, CFrame) -> CFrame) & ((CFrame, Vector3) -> Vector3)", "Inverse: (self: CFrame) -> CFrame", "Lerp: (self: CFrame, target: CFrame, alpha: number) -> CFrame", "ToWorldSpace: (self: CFrame, other: CFrame) -> CFrame", "ToObjectSpace: (self: CFrame, other: CFrame) -> CFrame", "PointToWorldSpace: (self: CFrame, point: Vector3) -> Vector3", "PointToObjectSpace: (self: CFrame, point: Vector3) -> Vector3"]
            }
            if owner == "Part" { members += ["CFrame: CFrame", "AssemblyLinearVelocity: Vector3", "AssemblyAngularVelocity: Vector3", "Velocity: Vector3"] }
            if owner == "Game" {
                members.removeAll { $0.hasPrefix("GetService:") || $0.hasPrefix("Workspace:") }
                let services = LuauAPI.services.sorted { $0.key < $1.key }.map { key, value in
                    "((self: Game, name: \(quote(key))) -> \(scene.places[key].map { "SceneNode\($0)" } ?? value))"
                }
                members += ["GetService: " + services.joined(separator: " & "), "Workspace: SceneNode\(scene.places["Workspace"] ?? 0)"]
            }
            declarations.append("declare class \(owner)\(isValue ? "" : " extends " + parent)\n" + members.joined(separator: "\n") + "\nend")
        }
        for (index, node) in scene.nodes.enumerated() {
            let baseType = catalog[node.className] != nil ? node.className : "Instance"
            var children: [String] = []
            var lookups: [String] = []
            var names = Set<String>()
            for child in scene.children(of: index) {
                let childName = scene.nodes[child].name
                let reserved = Set((catalog[baseType] ?? []).map(name)).union(inherited)
                guard !childName.contains("\0"), !reserved.contains(childName), names.insert(childName).inserted else { continue }
                children.append("[\(quote(childName))]: SceneNode\(child)")
                lookups.append("((self: SceneNode\(index), name: \(quote(childName)), timeout: number?) -> SceneNode\(child))")
            }
            if !lookups.isEmpty {
                children.append("WaitForChild: " + (lookups + ["((self: SceneNode\(index), name: string, timeout: number?) -> any)"]).joined(separator: " & "))
                let optional = lookups.map { $0.replacingOccurrences(of: "timeout: number?", with: "recursive: boolean?") }
                children.append("FindFirstChild: " + (optional.map { String($0.dropLast()) + "?)" } + ["((self: SceneNode\(index), name: string, recursive: boolean?) -> any)"]).joined(separator: " & "))
            }
            if let parent = node.parent { children.append("Parent: SceneNode\(parent)") }
            declarations.append("declare class SceneNode\(index) extends \(baseType)\n" + children.joined(separator: "\n") + "\nend")
        }
        for (namespace, members) in LuauAPI.staticMembers.sorted(by: { $0.key < $1.key }) where !["math", "string", "table", "Instance"].contains(namespace) {
            let fields = members.map { member($0, owner: namespace, instance: false) }.joined(separator: ",\n")
            if namespace.hasPrefix("Enum.") { declarations.append("type \(type(namespace)) = {\n\(fields)\n}") }
            else { declarations.append("declare \(namespace): {\n\(fields)\n}") }
        }
        let nativeMath: Set<String> = ["pi", "huge", "abs", "floor", "ceil", "round", "sqrt", "sin", "cos", "tan", "atan2", "min", "max", "clamp", "sign", "random", "rad", "deg", "noise", "fmod", "log", "exp"]
        let mathExtras = (LuauAPI.staticMembers["math"] ?? []).filter { !nativeMath.contains(name($0)) }.map { member($0, owner: "math", instance: false) }
        declarations.append("type StudioBuiltinMath = typeof(math)\ndeclare math: StudioBuiltinMath & {" + mathExtras.joined(separator: ",\n") + "}")
        let unavailable = Set(LuauAPI.services.values).union(["Instance", "Game", "BasePart", "PartOperation", "UnionOperation", "NegateOperation", "Light", "Script", "LocalScript", "ModuleScript", "Player", "PlayerGui", "Backpack", "Mouse", "BodyPart", "HumanoidRootPart", "Animator", "AnimationTrack", "Screen"])
        let classes = catalog.keys.sorted().filter { !values.contains($0) && !unavailable.contains($0) }
        declarations.append("declare Instance: {new: " + classes.map { "((className: \(quote($0)), parent: Instance?) -> \($0))" }.joined(separator: " & ") + "}")
        declarations.append("declare CFrame: {new: ((x: number?, y: number?, z: number?) -> CFrame) & ((position: Vector3, lookAt: Vector3?) -> CFrame), Angles: (number, number, number) -> CFrame, fromEulerAnglesXYZ: (number, number, number) -> CFrame, lookAt: (Vector3, Vector3, Vector3?) -> CFrame, identity: CFrame}")
        for (name, kind) in LuauAPI.globalInstances.sorted(by: { $0.key < $1.key }) where name != "script" {
            let value = name == "workspace" || name == "Workspace" ? "SceneNode\(scene.places["Workspace"] ?? 0)" : kind
            declarations.append("declare \(name): \(value)")
        }
        declarations += ["declare shared: {[any]: any}", "declare time: () -> number", "declare tick: () -> number", "declare warn: (...any) -> ()", "declare wait: (number?) -> number", "declare spawn: ((...any) -> ()) -> thread", "declare delay: (number, (...any) -> ()) -> thread"]
        return declarations.joined(separator: "\n")
    }
}
