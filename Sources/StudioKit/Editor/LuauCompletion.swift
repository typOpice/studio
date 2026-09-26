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
/// Pure functions over `(source, caret)`, so it is tested without a UI.
enum LuauCompletion {

    enum Context: Equatable {
        case namespace(String)    // `Vector3.` — static members
        case instance(String)     // `part.` — instance members
    }

    private struct Segment {
        var name: String
        var isCall = false
        var argument: String?     // the literal text of a call's argument, for GetService
    }

    private static let maximumItems = 60

    static func items(in text: String, caret: Int) -> [CompletionItem] {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        if LuauSyntax.isInCommentOrString(offset: caret, in: text) { return [] }

        let range = WrenCompletion.partialWordRange(in: text, caret: caret)
        let prefix = String(decoding: units[range.location..<(range.location + range.length)], as: UTF16.self)

        if range.location > 0 {
            let separator = units[range.location - 1]
            if separator == colon || separator == dot {
                // `..` is concatenation, not member access.
                if separator == dot, range.location > 1, units[range.location - 2] == dot { return [] }
                let candidates = memberItems(units: units, separatorIndex: range.location - 1,
                                             methodsOnly: separator == colon, text: text, caret: caret)
                return rank(candidates.map { ($0, $0.kind.rawValue) }, prefix: prefix)
            }
        }
        var lineStart = range.location
        while lineStart > 0, units[lineStart - 1] != newline { lineStart -= 1 }
        if isNamingSomething(String(decoding: units[lineStart..<range.location], as: UTF16.self)) { return [] }
        return rank(globalItems(text: text, caret: caret), prefix: prefix)
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

    // MARK: - Members

    private static func memberItems(units: [UInt16], separatorIndex: Int, methodsOnly: Bool,
                                    text: String, caret: Int) -> [CompletionItem] {
        guard let segments = receiverChain(units: units, before: separatorIndex),
              let context = resolve(segments: segments, text: text, caret: caret, visiting: [])
        else { return [] }

        switch context {
        case .namespace(let name):
            return methodsOnly ? [] : LuauAPI.members(ofStatic: name)
        case .instance(let type):
            let members = LuauAPI.members(ofInstance: type)
            // `.` shows properties, `:` shows methods — the same split Luau itself makes.
            return members.filter { methodsOnly ? $0.kind == .method : $0.kind != .method }
        }
    }

    /// Reads `a.b:c("x").d` backwards from a separator into segments a, b, c, d.
    private static func receiverChain(units: [UInt16], before separatorIndex: Int) -> [Segment]? {
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

    private static func resolve(segments: [Segment], text: String, caret: Int,
                                visiting: Set<String>) -> Context? {
        guard let head = segments.first else { return nil }

        var context: Context
        if let local = localType(of: head.name, text: text, caret: caret, visiting: visiting) {
            context = .instance(local)
        } else if let type = LuauAPI.globalInstances[head.name] {
            context = .instance(type)
        } else if LuauAPI.isNamespace(head.name) {
            context = .namespace(head.name)
        } else {
            return nil
        }

        for segment in segments.dropFirst() {
            guard let next = step(from: context, into: segment) else { return nil }
            context = next
        }
        return context
    }

    private static func step(from context: Context, into segment: Segment) -> Context? {
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
            guard let member = member(named: segment.name, in: LuauAPI.members(ofStatic: name)),
                  let returns = member.returns else { return nil }
            return contextFor(returns)

        case .instance(let type):
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
    }

    /// What a returned value is. `Vector3.new()` returns a Vector3 *value*, even though
    /// "Vector3" also names a namespace; only types with no instance members at all,
    /// like `Enum.Material`, stay namespaces.
    private static func contextFor(_ type: String) -> Context {
        if LuauAPI.instanceMembers[type] != nil { return .instance(type) }
        return LuauAPI.isNamespace(type) ? .namespace(type) : .instance(type)
    }

    private static func member(named name: String, in members: [CompletionItem]) -> CompletionItem? {
        members.first { $0.label == name || $0.label.hasPrefix("\(name)(") }
    }

    // MARK: - Locals

    /// The type of `local name = …` or `local name: Type = …` declared above the caret.
    private static func localType(of name: String, text: String, caret: Int, visiting: Set<String>) -> String? {
        guard !visiting.contains(name) else { return nil }
        let before = String(decoding: Array(text.utf16)[0..<min(caret, text.utf16.count)], as: UTF16.self)

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
            return annotation
        }
        return type(ofExpression: found.value, text: text, caret: caret, visiting: visiting.union([name]))
    }

    private static func type(ofExpression expression: String, text: String, caret: Int,
                             visiting: Set<String>) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if first == "\"" || first == "'" || first == "`" { return "string" }
        if first.isNumber { return "number" }
        if trimmed == "true" || trimmed == "false" { return "boolean" }

        // `script.Parent or workspace:FindFirstChild("Orb")` — take the first choice.
        let leading = trimmed.components(separatedBy: " or ").first ?? trimmed
        let probe = Array((leading + ".").utf16)
        guard let segments = receiverChain(units: probe, before: probe.count - 1),
              let context = resolve(segments: segments, text: text, caret: caret, visiting: visiting)
        else { return nil }
        if case .instance(let type) = context { return type }
        return nil
    }

    // MARK: - Top level

    /// Everything in scope, each with its place in the order: the script's own locals
    /// first (they're what it is about), then keywords, globals and functions, libraries,
    /// and the whole-line snippets last.
    private static func globalItems(text: String, caret: Int) -> [(CompletionItem, Int)] {
        var items: [(CompletionItem, Int)] = []
        let before = String(decoding: Array(text.utf16)[0..<min(caret, text.utf16.count)], as: UTF16.self)
        for name in declaredLocals(in: before) {
            let type = localType(of: name, text: text, caret: caret, visiting: [])
            items.append((CompletionItem(label: name, insert: name, detail: type ?? "local",
                                         kind: .variable, returns: type), 0))
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

    private static func isIdentifier(_ c: UInt16) -> Bool {
        (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == UInt16(UInt8(ascii: "_"))
    }

    private static func matchBackwards(_ units: [UInt16], from closeIndex: Int, open: UInt16, close: UInt16) -> Int? {
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
