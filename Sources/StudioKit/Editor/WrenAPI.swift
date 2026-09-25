import Foundation

/// One suggestion offered by the editor.
struct CompletionItem: Equatable {
    enum Kind: Int, Comparable {
        case property = 0
        case method = 1
        case variable = 2
        case type = 3
        case keyword = 4

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    /// Shown in the popup, e.g. `find(name)`.
    var label: String
    /// Typed into the document when chosen, e.g. `find(`.
    var insert: String
    /// The right-hand hint, usually the type the expression evaluates to.
    var detail: String
    var kind: Kind
    /// Type of the resulting value, used to resolve the next link in a chain.
    /// `List<Part>` means a list whose elements are `Part`.
    var returns: String?
}

/// Static description of everything a script can reach: the `studio` module plus the
/// parts of Wren's core library scripts actually use. Kept in step with
/// `StudioModule.swift` — when you add an API there, add it here too.
enum WrenAPI {

    private static func property(_ name: String, _ type: String) -> CompletionItem {
        CompletionItem(label: name, insert: name, detail: type, kind: .property, returns: type)
    }

    private static func method(_ name: String, _ arguments: String, _ type: String,
                               takesBlock: Bool = false) -> CompletionItem {
        CompletionItem(label: arguments.isEmpty ? "\(name)()" : "\(name)(\(arguments))",
                       // A method whose argument is a function reads better written as a
                       // trailing block, so it gets no opening paren.
                       insert: takesBlock ? "\(name) " : "\(name)(",
                       detail: type,
                       kind: .method,
                       returns: type == "null" ? nil : type)
    }

    /// Members reachable on the class itself, e.g. `Workspace.find`.
    static let staticMembers: [String: [CompletionItem]] = [
        "Vec3": [
            method("new", "x, y, z", "Vec3"),
            property("zero", "Vec3"), property("one", "Vec3"), property("up", "Vec3"),
            method("distance", "a, b", "Num"),
            method("onCircleY", "degrees, radius", "Vec3")
        ],
        "Color": [
            method("new", "r, g, b", "Color"),
            method("rgb", "r, g, b", "Color"),
            method("gray", "value", "Color"),
            method("hsv", "hue, saturation, value", "Color"),
            property("red", "Color"), property("green", "Color"), property("blue", "Color"),
            property("yellow", "Color"), property("white", "Color"), property("black", "Color")
        ],
        "Workspace": [
            property("parts", "List<Part>"),
            property("count", "Num"),
            method("find", "name", "Part"),
            method("findAll", "name", "List<Part>"),
            method("create", "shape", "Part"),
            method("create", "shape, position", "Part")
        ],
        "Player": [
            property("position", "Vec3"), property("velocity", "Vec3"),
            property("speed", "Num"), property("grounded", "Bool"),
            method("teleport", "position", "null")
        ],
        "Runtime": [
            property("time", "Num"),
            method("log", "message", "null"),
            method("onUpdate", "fn", "null", takesBlock: true)
        ],
        "System": [
            method("print", "value", "null"),
            method("write", "value", "null"),
            property("clock", "Num"),
            method("gc", "", "null")
        ],
        "Fn": [method("new", "fn", "Fn", takesBlock: true)],
        "Num": [
            property("pi", "Num"), property("infinity", "Num"), property("nan", "Num"),
            method("fromString", "text", "Num")
        ],
        "List": [method("filled", "count, value", "List"), method("new", "", "List")],
        "Map": [method("new", "", "Map")],
        "String": [method("fromCodePoint", "code", "String")],

        // The `math` module.
        "Math": [
            property("pi", "Num"), property("tau", "Num"), property("e", "Num"),
            property("epsilon", "Num"),
            method("clamp", "value, low, high", "Num"),
            method("saturate", "value", "Num"),
            method("lerp", "a, b, t", "Num"),
            method("lerpClamped", "a, b, t", "Num"),
            method("inverseLerp", "a, b, value", "Num"),
            method("remap", "value, fromLow, fromHigh, toLow, toHigh", "Num"),
            method("remapClamped", "value, fromLow, fromHigh, toLow, toHigh", "Num"),
            method("step", "edge, value", "Num"),
            method("smoothstep", "edge0, edge1, value", "Num"),
            method("smootherstep", "edge0, edge1, value", "Num"),
            method("sign", "value", "Num"),
            method("approximately", "a, b", "Bool"),
            method("degrees", "radians", "Num"),
            method("radians", "degrees", "Num"),
            method("wrapAngle", "degrees", "Num"),
            method("deltaAngle", "from, to", "Num"),
            method("moveTowardsAngle", "current, target, maxDelta", "Num"),
            method("wrap", "value, length", "Num"),
            method("pingPong", "value, length", "Num"),
            method("moveTowards", "current, target, maxDelta", "Num"),
            method("snap", "value, step", "Num"),
            method("minOf", "values", "Num"), method("maxOf", "values", "Num"),
            method("sum", "values", "Num"), method("average", "values", "Num")
        ],
        "Ease": [
            method("linear", "t", "Num"),
            method("inSine", "t", "Num"), method("outSine", "t", "Num"),
            method("inOutSine", "t", "Num"),
            method("inQuad", "t", "Num"), method("outQuad", "t", "Num"),
            method("inOutQuad", "t", "Num"),
            method("inCubic", "t", "Num"), method("outCubic", "t", "Num"),
            method("inOutCubic", "t", "Num"),
            method("inQuart", "t", "Num"), method("outQuart", "t", "Num"),
            method("inExpo", "t", "Num"), method("outExpo", "t", "Num"),
            method("inCirc", "t", "Num"), method("outCirc", "t", "Num"),
            method("inBack", "t", "Num"), method("outBack", "t", "Num"),
            method("outElastic", "t", "Num"),
            method("inBounce", "t", "Num"), method("outBounce", "t", "Num")
        ],
        "Rand": [
            method("seed", "value", "null"),
            property("float", "Num"), method("float", "high", "Num"),
            method("float", "low, high", "Num"),
            method("int", "high", "Num"), method("int", "low, high", "Num"),
            property("bool", "Bool"), property("sign", "Num"), property("angle", "Num"),
            method("pick", "items", "Object"), method("shuffle", "items", "List"),
            property("vec3", "Vec3"), method("vec3", "low, high", "Vec3"),
            property("direction", "Vec3"),
            method("onSphere", "radius", "Vec3"),
            method("insideSphere", "radius", "Vec3"),
            property("color", "Color")
        ],
        "Noise": [
            method("seed", "value", "null"),
            method("value", "x", "Num"), method("value", "x, y", "Num"),
            method("value", "x, y, z", "Num"),
            method("fbm", "x, y", "Num"), method("fbm", "x, y, octaves", "Num")
        ]
    ]

    /// Members reachable on an instance, e.g. `part.position`.
    static let instanceMembers: [String: [CompletionItem]] = [
        "Vec3": [
            property("x", "Num"), property("y", "Num"), property("z", "Num"),
            property("length", "Num"), property("lengthSquared", "Num"),
            property("normalized", "Vec3"), property("sum", "Num"),
            property("largestComponent", "Num"), property("smallestComponent", "Num"),
            property("abs", "Vec3"), property("floor", "Vec3"),
            property("ceil", "Vec3"), property("round", "Vec3"),
            method("dot", "other", "Num"), method("cross", "other", "Vec3"),
            method("lerp", "other, t", "Vec3"),
            method("distanceTo", "other", "Num"),
            method("withX", "value", "Vec3"), method("withY", "value", "Vec3"),
            method("withZ", "value", "Vec3"),
            method("scaled", "other", "Vec3"),
            method("min", "other", "Vec3"), method("max", "other", "Vec3"),
            method("reflect", "normal", "Vec3"),
            method("project", "axis", "Vec3"),
            method("angleTo", "other", "Num"),
            method("rotatedY", "degrees", "Vec3"),
            property("toString", "String")
        ],
        "Color": [
            property("r", "Num"), property("g", "Num"), property("b", "Num"),
            method("lerp", "other, t", "Color"),
            method("darkened", "t", "Color"), method("lightened", "t", "Color"),
            property("luma", "Num"), property("grayscale", "Color"),
            property("toString", "String")
        ],
        "Part": [
            property("name", "String"), property("shape", "String"),
            property("material", "String"), property("position", "Vec3"),
            property("size", "Vec3"), property("rotation", "Vec3"),
            property("color", "Color"), property("transparency", "Num"),
            property("anchored", "Bool"), property("visible", "Bool"),
            property("locked", "Bool"), property("exists", "Bool"),
            property("id", "String"),
            method("moveBy", "offset", "null"), method("rotateBy", "degrees", "null"),
            method("clone", "", "Part"), method("destroy", "", "null"),
            property("toString", "String")
        ],
        "Script": [
            property("id", "String"), property("name", "String"),
            property("parent", "Part"), property("toString", "String")
        ],
        "List": [
            property("count", "Num"), property("isEmpty", "Bool"),
            method("add", "item", "null"), method("addAll", "other", "List"),
            method("clear", "", "null"), method("insert", "index, item", "null"),
            method("removeAt", "index", "null"), method("indexOf", "item", "Num"),
            method("contains", "item", "Bool"), method("join", "separator", "String"),
            method("sort", "", "List"),
            method("each", "fn", "null", takesBlock: true),
            method("map", "fn", "Sequence", takesBlock: true),
            method("where", "fn", "Sequence", takesBlock: true),
            method("any", "fn", "Bool", takesBlock: true),
            method("all", "fn", "Bool", takesBlock: true),
            method("reduce", "fn", "Num", takesBlock: true),
            property("toList", "List")
        ],
        "String": [
            property("count", "Num"), property("isEmpty", "Bool"),
            method("contains", "text", "Bool"), method("startsWith", "text", "Bool"),
            method("endsWith", "text", "Bool"), method("indexOf", "text", "Num"),
            method("split", "separator", "List"), method("trim", "", "String"),
            method("replace", "old, new", "String"),
            property("bytes", "Sequence"), property("codePoints", "Sequence"),
            property("toString", "String")
        ],
        "Num": [
            property("abs", "Num"), property("ceil", "Num"), property("floor", "Num"),
            property("round", "Num"), property("sqrt", "Num"), property("sign", "Num"),
            property("sin", "Num"), property("cos", "Num"), property("tan", "Num"),
            property("asin", "Num"), property("acos", "Num"), property("atan", "Num"),
            property("log", "Num"), property("exp", "Num"), property("truncate", "Num"),
            property("fraction", "Num"), property("isNan", "Bool"),
            property("isInteger", "Bool"), property("isInfinity", "Bool"),
            method("pow", "power", "Num"), method("min", "other", "Num"),
            method("max", "other", "Num"), method("clamp", "low, high", "Num"),
            property("toString", "String")
        ],
        "Bool": [property("toString", "String")],
        "Map": [
            property("count", "Num"), property("keys", "Sequence"),
            property("values", "Sequence"), method("containsKey", "key", "Bool"),
            method("remove", "key", "null"), method("clear", "", "null")
        ],
        "Range": [
            property("from", "Num"), property("to", "Num"),
            property("min", "Num"), property("max", "Num"),
            property("isInclusive", "Bool")
        ],
        "Sequence": [
            property("count", "Num"), property("isEmpty", "Bool"),
            property("toList", "List"),
            method("each", "fn", "null", takesBlock: true),
            method("map", "fn", "Sequence", takesBlock: true),
            method("where", "fn", "Sequence", takesBlock: true)
        ]
    ]

    /// Classes offered at the top level, with the module a script imports them from.
    static let globalTypes: [String: String] = [
        "Workspace": "studio", "Part": "studio", "Vec3": "studio", "Color": "studio",
        "Player": "studio", "Runtime": "studio", "Script": "studio", "Studio": "studio",
        "Math": "math", "Ease": "math", "Rand": "math", "Noise": "math",
        "System": "core", "Fn": "core", "Fiber": "core", "List": "core", "Map": "core",
        "Num": "core", "String": "core", "Bool": "core", "Range": "core",
        "Sequence": "core", "Object": "core", "Null": "core"
    ]

    /// Ready-made lines for the things every script needs.
    static let snippets: [CompletionItem] = [
        CompletionItem(label: "import \"studio\" for ...",
                       insert: "import \"studio\" for Workspace, Runtime, Vec3, Color",
                       detail: "import the studio module", kind: .keyword, returns: nil),
        CompletionItem(label: "import \"math\" for ...",
                       insert: "import \"math\" for Math, Ease, Rand, Noise",
                       detail: "import the math module", kind: .keyword, returns: nil),
        CompletionItem(label: "script", insert: "script",
                       detail: "Script", kind: .variable, returns: "Script")
    ]

    static func members(ofStatic className: String) -> [CompletionItem] {
        staticMembers[className] ?? []
    }

    static func members(ofInstance typeName: String) -> [CompletionItem] {
        instanceMembers[elementFree(typeName)] ?? []
    }

    /// `List<Part>` → `List`.
    static func elementFree(_ type: String) -> String {
        guard let bracket = type.firstIndex(of: "<") else { return type }
        return String(type[type.startIndex..<bracket])
    }

    /// `List<Part>` → `Part`.
    static func elementType(of type: String) -> String? {
        guard let open = type.firstIndex(of: "<"), let close = type.lastIndex(of: ">") else { return nil }
        return String(type[type.index(after: open)..<close])
    }

    static func isKnownType(_ name: String) -> Bool {
        globalTypes[name] != nil || staticMembers[name] != nil || instanceMembers[name] != nil
    }
}
