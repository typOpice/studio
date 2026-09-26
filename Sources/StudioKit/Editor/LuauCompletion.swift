import Foundation

/// Works out what to offer at the caret in a Luau script.
///
/// After `.` or `:` it resolves the type of the expression to the left and offers
/// that type's properties (`.`) or methods (`:`), walking chains through return
/// types — including `game:GetService("RunService")`, which resolves by its string
/// argument, because that is how nearly every Roblox script begins. Otherwise it
/// offers keywords, globals and the locals declared above the caret — except where a
/// new name is being made up (`local x`, `for i`, a function's name and parameters),
/// where any suggestion would only be in the way.
///
/// Inside `game:GetService("…")` (or right after `GetService(`) it offers the services,
/// the one named like the local being declared first.
///
/// Given the scene (`LuauScene`), it also knows what is really there: the children of
/// `ReplicatedStorage`, `workspace.Model` or `script.Parent` by name, the names inside
/// `WaitForChild("…")`, every ModuleScript right after `require(`, and — by reading the
/// module's code — what a required module hands back: `Utils.` lists its functions and
/// values, and an object its constructor makes lists its methods.
///
/// Pure functions over `(source, caret, scene)`, so it is tested without a UI.
enum LuauCompletion {

    enum Context: Equatable {
        case namespace(String)    // `Vector3.` — static members
        case instance(String)     // `part.` — instance members
        case node(Int)            // something in the scene, by its index in `LuauScene.nodes`
        case module([LuauModuleShape.Member])  // what a module returned, a table in it, or an object it made
    }

    fileprivate struct Segment {
        var name: String
        var isCall = false
        var argument: String?     // the literal text of a call's argument, for GetService
    }

    private static let maximumItems = 60

    static func items(in text: String, caret: Int, scene: LuauScene? = nil) -> [CompletionItem] {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        let resolver = Resolver(text: text, units: units, caret: caret, scene: scene)

        // `:GetService("Pl|")`: the services; `:WaitForChild("Na|")`: what is really there.
        if let argument = nameArgument(units: units, caret: caret) {
            let typed = String(decoding: units[argument.start..<caret], as: UTF16.self)
            if argument.method == "GetService" {
                return rank(resolver.serviceItems(quote: units[argument.start - 1]), prefix: typed)
            }
            return rank(resolver.childNameItems(quote: argument.start - 1).map { ($0, 0) }, prefix: typed)
        }
        if LuauSyntax.isInCommentOrString(offset: caret, in: text) { return [] }

        let range = WrenCompletion.partialWordRange(in: text, caret: caret)
        let prefix = String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)
        // `game:GetService(` before the quote: the services, quoted for you.
        if isArgument(of: "GetService", units: units, at: range.location, afterColon: true) {
            return rank(resolver.serviceItems(quote: nil), prefix: prefix)
        }

        if range.location > 0 {
            let separator = units[range.location - 1]
            if separator == colon || separator == dot {
                // `..` is concatenation, not member access.
                if separator == dot, range.location > 1, units[range.location - 2] == dot { return [] }
                return rank(resolver.memberItems(separatorIndex: range.location - 1, methodsOnly: separator == colon),
                            prefix: prefix)
            }
        }
        var lineStart = range.location
        while lineStart > 0, units[lineStart - 1] != newline { lineStart -= 1 }
        if isNamingSomething(String(decoding: units[lineStart..<range.location], as: UTF16.self)) { return [] }
        var items = resolver.globalItems()
        if isRequireArgument(units: units, at: range.location) {
            // Only what a path to a module can start from: the modules themselves, the
            // script's locals, and `script`, `game` and `workspace`.
            let roots: Set<String> = ["script", "game", "workspace"]
            items = resolver.modulePathItems() + items.filter { $0.1 == 0 || roots.contains($0.0.label) }
        }
        return rank(items, prefix: prefix)
    }

    /// Where a chosen suggestion's text starts: inside `WaitForChild("…")`, just after the
    /// quote (a name may have spaces); anywhere else, the start of the word.
    static func replacementStart(in text: String, caret: Int) -> Int {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        return nameArgument(units: units, caret: caret)?.start ?? WrenCompletion.partialWordRange(in: text, caret: caret).location
    }

    /// Where the list should open without waiting for a pause: straight after
    /// `require(` or `GetService(`, and after the opening quote of `GetService("` or
    /// `WaitForChild("`.
    static func opensAtOnce(in text: String, caret: Int) -> Bool {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        if let argument = nameArgument(units: units, caret: caret) { return argument.start == caret }
        return isRequireArgument(units: units, at: caret)
            || isArgument(of: "GetService", units: units, at: caret, afterColon: true)
    }

    /// Whether suggestions belong at the caret even though it's in a string: the name
    /// inside `GetService("…")`, `WaitForChild("…")` or `FindFirstChild("…")`.
    static func isNameArgument(in text: String, caret: Int) -> Bool {
        let units = Array(text.utf16)
        return nameArgument(units: units, caret: min(max(caret, 0), units.count)) != nil
    }

    /// Whether the line so far leaves the caret where a new name goes: `local na`,
    /// `local a, b`, `local x: T`, `local function na`, `function na`, `for i`,
    /// `for _, v`, or inside a function's parameter list.
    static func isNamingSomething(_ lineBefore: String) -> Bool {
        let line = lineBefore.drop { $0 == " " || $0 == "\t" }
        if let keyword = lastWord("function", in: line) {
            let rest = line[keyword.upperBound...]
            if let open = rest.firstIndex(of: "(") { return !rest[open...].contains(")") }
            // `function name` or `local function name`, before its parenthesis.
            return rest.first == " " && rest.dropFirst().allSatisfy { $0.isLetter || $0.isNumber || "_.: ".contains($0) }
        }
        if line.hasPrefix("local ") { return !line.contains("=") }
        if line.hasPrefix("for ") { return !line.contains("=") && !line.contains(" in ") }
        return false
    }

    /// The last place `word` appears as a whole word.
    private static func lastWord(_ word: String, in line: Substring) -> Range<Substring.Index>? {
        var searchEnd = line.endIndex
        while let found = line.range(of: word, options: .backwards, range: line.startIndex..<searchEnd) {
            let before = found.lowerBound > line.startIndex ? line[line.index(before: found.lowerBound)] : " "
            let after = found.upperBound < line.endIndex ? line[found.upperBound] : " "
            let isPart: (Character) -> Bool = { $0.isLetter || $0.isNumber || $0 == "_" }
            if !isPart(before) && !isPart(after) { return found }
            searchEnd = found.lowerBound
        }
        return nil
    }

    // MARK: - Where the caret is

    /// `require(` just before `index` (spaces allowed), with only a word typed since.
    fileprivate static func isRequireArgument(units: [UInt16], at index: Int) -> Bool {
        isArgument(of: "require", units: units, at: index, afterColon: false)
    }

    /// `function(` just before `index` (spaces allowed), with only a word typed since;
    /// for a method, with a colon before its name.
    fileprivate static func isArgument(of function: String, units: [UInt16], at index: Int, afterColon: Bool) -> Bool {
        var i = index
        while i > 0, isIdentifier(units[i - 1]) { i -= 1 }
        while i > 0, units[i - 1] == space { i -= 1 }
        guard i > 0, units[i - 1] == leftParen, word(endingAt: i - 1, in: units) == function else { return false }
        let start = i - 1 - function.utf16.count
        if afterColon { return start > 0 && units[start - 1] == colon }
        return start == 0 || !(units[start - 1] == dot || units[start - 1] == colon)
    }

    /// Inside the string that is the first argument of `:GetService(`, `:WaitForChild(` or
    /// `:FindFirstChild(`: which of them, and the offset just after the opening quote.
    fileprivate static func nameArgument(units: [UInt16], caret: Int) -> (start: Int, method: String)? {
        var quote = caret
        while quote > 0 {
            let c = units[quote - 1]
            if c == newline { return nil }
            if c == doubleQuote || c == singleQuote { break }
            quote -= 1
        }
        guard quote > 0 else { return nil }
        let opening = quote - 1
        var i = opening
        while i > 0, units[i - 1] == space { i -= 1 }
        guard i > 0, units[i - 1] == leftParen else { return nil }
        let method = word(endingAt: i - 1, in: units)
        guard ["GetService", "WaitForChild", "FindFirstChild"].contains(method) else { return nil }
        let methodStart = i - 1 - method.utf16.count
        guard methodStart > 0, units[methodStart - 1] == colon else { return nil }
        return (quote, method)
    }

    /// The identifier that ends just before `end`.
    fileprivate static func word(endingAt end: Int, in units: [UInt16]) -> String {
        var start = end
        while start > 0, isIdentifier(units[start - 1]) { start -= 1 }
        return String(decoding: units[start..<end], as: UTF16.self)
    }

    // MARK: - Resolving

    /// Everything that needs the text, the caret and the scene together.
    fileprivate struct Resolver {
        let text: String
        let units: [UInt16]
        let caret: Int
        let scene: LuauScene?

        // MARK: Members

        func memberItems(separatorIndex: Int, methodsOnly: Bool) -> [(CompletionItem, Int)] {
            guard let segments = LuauCompletion.receiverChain(units: units, before: separatorIndex),
                  let context = resolve(segments: segments, visiting: [])
            else { return [] }
            // Inside `require(…)`, only what leads to a ModuleScript is any use.
            let inRequire = requireEncloses(chainEndingAt: separatorIndex)

            switch context {
            case .namespace(let name):
                return methodsOnly ? [] : LuauAPI.members(ofStatic: name).map { ($0, $0.kind.rawValue) }
            case .instance(let type):
                let members = LuauAPI.members(ofInstance: type)
                // `.` shows properties, `:` shows methods — the same split Luau itself makes.
                return members.filter { methodsOnly ? $0.kind == .method : $0.kind != .method }.map { ($0, $0.kind.rawValue) }
            case .node(let index):
                guard let scene else { return [] }
                let node = scene.nodes[index]
                let members = LuauAPI.members(ofInstance: node.className)
                if methodsOnly { return members.filter { $0.kind == .method }.map { ($0, 1) } }
                var items: [(CompletionItem, Int)] = []
                for child in scene.children(of: index) where isPlainName(scene.nodes[child].name) {
                    if inRequire && !scene.leadsToModule(child) { continue }
                    items.append((childItem(child, in: scene), 0))
                }
                if !inRequire { items += members.filter { $0.kind != .method }.map { ($0, 1) } }
                return items
            case .module(let members):
                return members.filter { $0.isMethod == methodsOnly && !$0.name.hasPrefix("__") }.map { (item(for: $0), 0) }
            }
        }

        /// A module's function or value as a suggestion.
        private func item(for member: LuauModuleShape.Member) -> CompletionItem {
            if let parameters = member.parameters {
                return CompletionItem(label: "\(member.name)(\(parameters))", insert: "\(member.name)(",
                                      detail: member.isMethod ? "method" : "function", kind: .method, returns: nil)
            }
            return CompletionItem(label: member.name, insert: member.name, detail: member.detail,
                                  kind: .property, returns: nil)
        }

        private func childItem(_ index: Int, in scene: LuauScene) -> CompletionItem {
            let node = scene.nodes[index]
            return CompletionItem(label: node.name, insert: node.name, detail: node.className,
                                  kind: scene.isModule(index) ? .module : .object, returns: nil)
        }

        /// Whether the chain ending at `separatorIndex` is the argument of `require(`.
        private func requireEncloses(chainEndingAt separatorIndex: Int) -> Bool {
            // Walk back over the chain itself: names, dots, colons and bracketed calls.
            var i = separatorIndex
            while i > 0 {
                let c = units[i - 1]
                if isIdentifier(c) || c == dot || c == colon {
                    i -= 1
                } else if c == rightParen, let open = matchBackwards(units, from: i - 1, open: leftParen, close: rightParen) {
                    i = open
                } else {
                    break
                }
            }
            return LuauCompletion.isRequireArgument(units: units, at: i)
        }

        // MARK: Services

        /// Every service `game:GetService` knows. The one named like the local this line
        /// declares comes first (`local Players = game:GetService("`), and those the
        /// script already has come last. `quote` is the string's opening quote, or nil
        /// before there is one — then the quotes are put in too.
        func serviceItems(quote: UInt16?) -> [(CompletionItem, Int)] {
            let before = String(decoding: units[0..<caret], as: UTF16.self)
            let lineStart = before.lastIndex(of: "\n").map { before.index(after: $0) } ?? before.startIndex
            let line = before[lineStart...].drop { $0 == " " || $0 == "\t" }
            var declaring: String?
            if line.hasPrefix("local "), let equals = line.firstIndex(of: "=") {
                declaring = line[line.index(line.startIndex, offsetBy: 6)..<equals]
                    .split(separator: ":").first?.trimmingCharacters(in: .whitespaces)
            }
            var already = Set<String>()
            for name in LuauCompletion.declaredLocals(in: String(before[..<lineStart])) {
                if case .instance(let type)? = localContext(of: name, visiting: []) { already.insert(type) }
                if case .node(let index)? = localContext(of: name, visiting: []), let scene,
                   scene.nodes[index].parent == nil { already.insert(scene.nodes[index].name) }
            }
            let after = caret < units.count ? units[caret] : 0
            return LuauAPI.services.keys.map { name in
                let insert: String
                if let quote {
                    insert = after == quote ? name : name + String(decoding: [quote, rightParen], as: UTF16.self)
                } else {
                    insert = "\"\(name)\"" + (after == rightParen ? "" : ")")
                }
                let group = name == declaring ? -1 : already.contains(LuauAPI.services[name] ?? name) ? 1 : 0
                return (CompletionItem(label: name, insert: insert, detail: "service", kind: .object,
                                       returns: LuauAPI.services[name]), group)
            }
        }

        // MARK: Names in WaitForChild("…")

        func childNameItems(quote: Int) -> [CompletionItem] {
            guard let scene else { return [] }
            // `receiver:WaitForChild("` — the colon is just before the method's name.
            var i = quote
            while i > 0, units[i - 1] == space { i -= 1 }
            let method = LuauCompletion.word(endingAt: i - 1, in: units)
            let colonIndex = i - 1 - method.utf16.count - 1
            guard colonIndex > 0, let segments = LuauCompletion.receiverChain(units: units, before: colonIndex),
                  case .node(let index) = resolve(segments: segments, visiting: []) else { return [] }
            let inRequire = requireEncloses(chainEndingAt: colonIndex)
            // Close the string and the call, unless they're closed already.
            let after = caret < units.count ? units[caret] : 0
            let closing = after == units[quote] ? "" : String(decoding: [units[quote], rightParen], as: UTF16.self)
            return scene.children(of: index).compactMap { child in
                if inRequire && !scene.leadsToModule(child) { return nil }
                var item = childItem(child, in: scene)
                item.insert += closing
                return item
            }
        }

        // MARK: require(

        /// Every ModuleScript, as the path that reaches it from this script: beside it
        /// (`script.Parent.Helper`), or from its place — through the script's own
        /// `local ReplicatedStorage = game:GetService(…)` if it has one.
        func modulePathItems() -> [(CompletionItem, Int)] {
            guard let scene else { return [] }
            let after = caret < units.count ? units[caret] : 0
            let closing = after == rightParen ? "" : ")"
            let scriptParent = scene.script.flatMap { scene.nodes[$0].parent }
            let locals = LuauCompletion.declaredLocals(in: String(decoding: units[0..<caret], as: UTF16.self))
            return scene.modules.compactMap { module in
                guard module != scene.script else { return nil }
                let (place, names) = scene.path(to: module)
                var path: String
                var ancestorNames: [String] = []
                if let scriptParent, let fromParent = self.names(from: scriptParent, to: module, in: scene) {
                    path = "script.Parent" + fromParent.map(accessor).joined()
                    ancestorNames = ["script.Parent"] + fromParent.dropLast()
                } else {
                    let placeLocal = locals.first { name in
                        if case .node(let index)? = localContext(of: name, visiting: []) { return scene.nodes[index].name == place && scene.nodes[index].parent == nil }
                        return false
                    }
                    let base = place == "Workspace" ? "workspace" : placeLocal ?? "game:GetService(\"\(place)\")"
                    path = base + names.map(accessor).joined()
                    ancestorNames = [place] + names.dropLast()
                }
                path += closing
                return (CompletionItem(label: scene.nodes[module].name, insert: path,
                                       detail: ancestorNames.joined(separator: "."), kind: .module, returns: nil), -1)
            }
        }

        /// The names from `ancestor` down to `node`, if it is under it.
        private func names(from ancestor: Int, to node: Int, in scene: LuauScene) -> [String]? {
            var names: [String] = []
            var current = node
            while current != ancestor {
                names.insert(scene.nodes[current].name, at: 0)
                guard let parent = scene.nodes[current].parent else { return nil }
                current = parent
            }
            return names
        }

        private func accessor(_ name: String) -> String {
            isPlainName(name) ? ".\(name)" : "[\"\(name)\"]"
        }

        // MARK: Chains

        func resolve(segments: [Segment], visiting: Set<String>) -> Context? {
            guard let head = segments.first else { return nil }

            var context: Context
            if head.name == "require", head.isCall, let argument = head.argument {
                // What the module hands back, read from its code.
                guard case .node(let index)? = self.context(ofExpression: argument, visiting: visiting),
                      let source = scene?.nodes[index].source else { return nil }
                context = .module(LuauModuleShape.members(of: source))
            } else if let local = localContext(of: head.name, visiting: visiting) {
                context = local
            } else if head.name == "script", let script = scene?.script {
                context = .node(script)
            } else if let type = LuauAPI.globalInstances[head.name] {
                context = refine(.instance(type))
            } else if LuauAPI.isNamespace(head.name) {
                context = .namespace(head.name)
            } else {
                return nil
            }
            if head.name != "require", head.isCall { return nil }

            for segment in segments.dropFirst() {
                guard let next = step(from: context, into: segment) else { return nil }
                context = refine(next)
            }
            return context
        }

        /// A service or `workspace` becomes the real place, when the scene is known.
        private func refine(_ context: Context) -> Context {
            guard let scene, case .instance(let type) = context, let place = scene.places[type] else { return context }
            return .node(place)
        }

        private func step(from context: Context, into segment: Segment) -> Context? {
            switch context {
            case .namespace(let name):
                // `Instance.new("HingeConstraint")` is a hinge, not a part.
                if name == "Instance", segment.name == "new", let className = segment.argument,
                   LuauAPI.instanceMembers[className] != nil {
                    return .instance(className)
                }
                // `Enum.Material` leads to another namespace; everything else to a value.
                if LuauAPI.isNamespace("\(name).\(segment.name)") {
                    return .namespace("\(name).\(segment.name)")
                }
                guard let member = LuauCompletion.member(named: segment.name, in: LuauAPI.members(ofStatic: name)),
                      let returns = member.returns else { return nil }
                return LuauCompletion.contextFor(returns)

            case .instance(let type):
                return LuauCompletion.step(fromInstance: type, into: segment)

            case .node(let index):
                guard let scene else { return nil }
                let node = scene.nodes[index]
                if !segment.isCall {
                    if segment.name == "Parent" {
                        return node.parent.map { .node($0) } ?? .instance("Game")
                    }
                    if let child = scene.child(named: segment.name, of: index) { return .node(child) }
                } else if segment.name == "WaitForChild" || segment.name == "FindFirstChild",
                          let name = segment.argument, let child = scene.child(named: name, of: index) {
                    return .node(child)
                } else if segment.name == "Clone" {
                    return .node(index)
                }
                return LuauCompletion.step(fromInstance: node.className, into: segment)

            case .module(let members):
                guard let member = members.first(where: { $0.name == segment.name }) else { return nil }
                if segment.isCall { return member.makes.isEmpty ? nil : .module(member.makes) }
                if !member.fields.isEmpty { return .module(member.fields) }
                if LuauAPI.instanceMembers[member.detail] != nil || LuauAPI.isNamespace(member.detail) {
                    return .instance(member.detail)
                }
                return nil
            }
        }

        // MARK: Locals

        /// What `local name = …` or `local name: Type = …`, declared above the caret, holds.
        func localContext(of name: String, visiting: Set<String>) -> Context? {
            guard !visiting.contains(name) else { return nil }
            let before = String(decoding: units[0..<caret], as: UTF16.self)

            var found: (annotation: String?, value: String)?
            for line in before.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("local "), !trimmed.hasPrefix("local function") else { continue }
                let body = trimmed.dropFirst(6)
                guard let equals = body.firstIndex(of: "=") else { continue }
                let declaration = body[body.startIndex..<equals]
                let parts = declaration.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard parts.first == name else { continue }
                let value = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                found = (parts.count > 1 ? parts[1] : nil, value)
            }
            guard let found else { return nil }

            if let annotation = found.annotation, LuauAPI.instanceMembers[annotation] != nil {
                return .instance(annotation)
            }
            return context(ofExpression: found.value, visiting: visiting.union([name]))
        }

        func context(ofExpression expression: String, visiting: Set<String>) -> Context? {
            let trimmed = expression.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { return nil }
            if first == "\"" || first == "'" || first == "`" { return .instance("string") }
            if first.isNumber { return .instance("number") }
            if trimmed == "true" || trimmed == "false" { return .instance("boolean") }

            // `script.Parent or workspace:FindFirstChild("Orb")` — take the first choice.
            let leading = trimmed.components(separatedBy: " or ").first ?? trimmed
            let probe = Array((leading + ".").utf16)
            guard let segments = LuauCompletion.receiverChain(units: probe, before: probe.count - 1) else { return nil }
            return resolve(segments: segments, visiting: visiting)
        }

        // MARK: Top level

        /// Everything in scope, each with its place in the order: the script's own locals
        /// first (they're what it is about), then keywords, globals and functions, libraries,
        /// and the whole-line snippets last.
        func globalItems() -> [(CompletionItem, Int)] {
            var items: [(CompletionItem, Int)] = []
            var before = String(decoding: units[0..<caret], as: UTF16.self)
            // A local being declared on this line isn't in scope until it ends:
            // `local count = cou` means some other count.
            let lineStart = before.lastIndex(of: "\n").map { before.index(after: $0) } ?? before.startIndex
            let line = before[lineStart...].drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("local "), !line.hasPrefix("local function"), line.contains("=") {
                before = String(before[..<lineStart])
            }
            for name in LuauCompletion.declaredLocals(in: before) {
                let context = localContext(of: name, visiting: [])
                items.append((CompletionItem(label: name, insert: name, detail: describe(context) ?? "local",
                                             kind: .variable, returns: nil), 0))
            }
            for keyword in LuauSyntax.keywords.sorted() {
                items.append((CompletionItem(label: keyword, insert: keyword, detail: "keyword", kind: .keyword, returns: nil), 1))
            }
            for (name, type) in LuauAPI.globalInstances {
                items.append((CompletionItem(label: name, insert: name, detail: type, kind: .variable, returns: type), 2))
            }
            items += LuauAPI.globalFunctions.map { ($0, 2) }
            for name in LuauAPI.staticMembers.keys where !name.contains(".") {
                items.append((CompletionItem(label: name, insert: name, detail: "library", kind: .type, returns: nil), 3))
            }
            items += LuauAPI.snippets.map { ($0, 4) }
            return items
        }

        /// A local's hint in the list: its type, what it is in the scene, or "module".
        private func describe(_ context: Context?) -> String? {
            switch context {
            case .instance(let type)?: return type
            case .namespace(let name)?: return name
            case .node(let index)?: return scene?.nodes[index].className
            case .module?: return "module"
            case nil: return nil
            }
        }
    }

    // MARK: - Chains

    /// Reads `a.b:c("x").d` backwards from a separator into segments a, b, c, d.
    fileprivate static func receiverChain(units: [UInt16], before separatorIndex: Int) -> [Segment]? {
        var index = separatorIndex
        var segments: [Segment] = []

        while true {
            guard index > 0 else { return nil }
            var segment = Segment(name: "")

            if units[index - 1] == rightParen {
                guard let open = matchBackwards(units, from: index - 1, open: leftParen, close: rightParen)
                else { return nil }
                segment.isCall = true
                let inner = String(decoding: units[(open + 1)..<(index - 1)], as: UTF16.self)
                segment.argument = inner.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                index = open
            }

            var start = index
            while start > 0, isIdentifier(units[start - 1]) { start -= 1 }
            guard start < index else { return nil }
            segment.name = String(decoding: units[start..<index], as: UTF16.self)
            segments.insert(segment, at: 0)

            if start > 0, units[start - 1] == dot || units[start - 1] == colon {
                index = start - 1
                continue
            }
            return segments
        }
    }

    /// One step from an instance of a type, by what the API tables say it has.
    fileprivate static func step(fromInstance type: String, into segment: Segment) -> Context? {
        if type == "Game", segment.name == "GetService", let argument = segment.argument {
            return LuauAPI.services[argument].map { .instance($0) }
        }
        // `character:WaitForChild("Humanoid")` — a character's children by name.
        if type == "Model", segment.name == "WaitForChild" || segment.name == "FindFirstChild",
           let argument = segment.argument {
            switch argument {
            case "Humanoid": return .instance("Humanoid")
            case "HumanoidRootPart": return .instance("HumanoidRootPart")
            default: return .instance("BodyPart")
            }
        }
        if let member = member(named: segment.name, in: LuauAPI.members(ofInstance: type)),
           let returns = member.returns {
            return contextFor(returns)
        }
        // `workspace.Baseplate` — children are reachable by name.
        if type == "Workspace", !segment.isCall { return .instance("Part") }
        if type == "Shaders", !segment.isCall { return .instance("Shader") }
        if type == "Animations", !segment.isCall { return .instance("Animation") }
        // `character["Left Arm"]` and friends: the rest of a character is body parts.
        if type == "Model", !segment.isCall { return .instance("BodyPart") }
        return nil
    }

    /// What a returned value is. `Vector3.new()` returns a Vector3 *value*, even though
    /// "Vector3" also names a namespace; only types with no instance members at all,
    /// like `Enum.Material`, stay namespaces.
    fileprivate static func contextFor(_ type: String) -> Context {
        if LuauAPI.instanceMembers[type] != nil { return .instance(type) }
        return LuauAPI.isNamespace(type) ? .namespace(type) : .instance(type)
    }

    fileprivate static func member(named name: String, in members: [CompletionItem]) -> CompletionItem? {
        members.first { $0.label == name || $0.label.hasPrefix("\(name)(") }
    }

    /// `local x`, `local a, b`, `local function f`, and function parameters.
    static func declaredLocals(in text: String) -> [String] {
        var names: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("local function ") {
                let name = trimmed.dropFirst(15).prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                if !name.isEmpty { names.append(String(name)) }
            } else if trimmed.hasPrefix("local ") {
                let declaration = trimmed.dropFirst(6).prefix { $0 != "=" }
                for piece in declaration.split(separator: ",") {
                    let name = piece.split(separator: ":").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                        names.append(name)
                    }
                }
            }
            if let open = line.range(of: "function"), let paren = line[open.upperBound...].firstIndex(of: "("),
               let close = line[paren...].firstIndex(of: ")") {
                for piece in line[line.index(after: paren)..<close].split(separator: ",") {
                    let name = piece.split(separator: ":").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    if !name.isEmpty, name != "...", name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
                        names.append(name)
                    }
                }
            }
        }
        return Array(Set(names)).sorted()
    }

    // MARK: - Ranking

    /// Matches for the typed prefix, best first. Case is ignored for matching but not for
    /// order: `en` puts `end` before `Enum`, `Ve` puts `Vector3` before `velocity`.
    /// Then by `group` (the caller's order of importance), then alphabetically.
    private static func rank(_ items: [(CompletionItem, Int)], prefix: String) -> [CompletionItem] {
        let lowered = prefix.lowercased()
        let matched = items.filter { lowered.isEmpty || $0.0.label.lowercased().hasPrefix(lowered) }
        let sorted = matched.sorted { a, b in
            let caseA = a.0.label.hasPrefix(prefix), caseB = b.0.label.hasPrefix(prefix)
            if caseA != caseB { return caseA }
            if a.1 != b.1 { return a.1 < b.1 }
            return a.0.label.localizedCaseInsensitiveCompare(b.0.label) == .orderedAscending
        }
        // The same name from two places (a local shadowing a global) is listed once.
        var seen: Set<String> = []
        return Array(sorted.map(\.0).filter { seen.insert($0.label).inserted }.prefix(maximumItems))
    }

    // MARK: - Characters

    private static let dot = UInt16(UInt8(ascii: "."))
    private static let colon = UInt16(UInt8(ascii: ":"))
    private static let leftParen = UInt16(UInt8(ascii: "("))
    private static let rightParen = UInt16(UInt8(ascii: ")"))
    private static let newline = UInt16(UInt8(ascii: "\n"))
    private static let space = UInt16(UInt8(ascii: " "))
    private static let doubleQuote = UInt16(UInt8(ascii: "\""))
    private static let singleQuote = UInt16(UInt8(ascii: "'"))

    fileprivate static func isIdentifier(_ c: UInt16) -> Bool {
        (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == UInt16(UInt8(ascii: "_"))
    }

    /// A name `a.b` can reach: letters, digits and underscores, not starting with a digit.
    fileprivate static func isPlainName(_ name: String) -> Bool {
        guard let first = name.utf16.first, !(first >= 48 && first <= 57) else { return false }
        return name.utf16.allSatisfy(isIdentifier)
    }

    fileprivate static func matchBackwards(_ units: [UInt16], from closeIndex: Int, open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var index = closeIndex
        while index >= 0 {
            if units[index] == close { depth += 1 }
            if units[index] == open {
                depth -= 1
                if depth == 0 { return index }
            }
            index -= 1
        }
        return nil
    }
}
