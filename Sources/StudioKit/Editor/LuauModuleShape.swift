import Foundation

/// What a ModuleScript hands back from `require`, read from its code without running it,
/// so completion can list it: `Utils.` → `lerp(a, b, t)`, `VERSION`, `settings`.
///
/// It follows the shapes modules are nearly always written in:
///
/// ```lua
/// local M = {}                   -- or  local M = { speed = 16, jump = function(h) … end }
/// M.speed = 16                    -- a value
/// function M.lerp(a, b, t) … end  -- a function, called with a dot
/// function M:Start() … end        -- a method, called with a colon
/// return M                        -- or  return { … }
/// ```
///
/// and a class's constructor (a function that calls `setmetatable`) makes objects with
/// the module's methods and every `self.name = …` field. Anything cleverer is simply
/// not listed.
enum LuauModuleShape {
    struct Member: Equatable {
        var name: String
        /// A function's parameters, as written; nil for a value.
        var parameters: String?
        /// `function M:name` — called with a colon.
        var isMethod = false
        /// For a value: number, string, boolean, table, Vector3…
        var detail = "value"
        /// A table's own fields.
        var fields: [Member] = []
        /// What calling it makes, for a constructor: the object's members.
        var makes: [Member] = []
    }

    /// The members of what `source` returns.
    static func members(of source: String) -> [Member] {
        let tokens = Scanner.tokens(of: source)
        var reader = Reader(tokens: tokens)
        return reader.exports()
    }

    // MARK: - Tokens

    enum Token: Equatable {
        case name(String)      // identifiers and keywords
        case number
        case string
        case symbol(String)
    }

    /// Luau split into the tokens this needs, with comments dropped and every string
    /// (quoted, backtick or long-bracket) a single token.
    enum Scanner {
        static func tokens(of source: String) -> [Token] {
            let units = Array(source.utf16)
            var skip: [NSRange] = []
            var strings = Set<Int>()
            for token in LuauSyntax.tokenize(source) where token.kind == .comment || token.kind == .string || token.kind == .escape {
                skip.append(token.range)
                if token.kind == .string { strings.insert(token.range.location) }
            }
            skip.sort { $0.location < $1.location }

            var tokens: [Token] = []
            var index = 0
            var next = 0
            while index < units.count {
                while next < skip.count, skip[next].location + skip[next].length <= index { next += 1 }
                if next < skip.count, skip[next].location <= index {
                    let range = skip[next]
                    if strings.contains(range.location), tokens.last != .string { tokens.append(.string) }
                    index = max(index + 1, range.location + range.length)
                    continue
                }
                let c = units[index]
                if isSpace(c) {
                    index += 1
                } else if isLetter(c) {
                    let start = index
                    while index < units.count, isLetter(units[index]) || isDigit(units[index]) { index += 1 }
                    tokens.append(.name(String(decoding: units[start..<index], as: UTF16.self)))
                } else if isDigit(c) {
                    while index < units.count, isLetter(units[index]) || isDigit(units[index]) || units[index] == 46 { index += 1 }
                    tokens.append(.number)
                } else if c == 46, index + 1 < units.count, units[index + 1] == 46 {
                    // `..` and `...`
                    var end = index + 2
                    if end < units.count, units[end] == 46 { end += 1 }
                    tokens.append(.symbol(String(decoding: units[index..<end], as: UTF16.self)))
                    index = end
                } else if index + 1 < units.count, units[index + 1] == 61, [61, 126, 60, 62].contains(c) {
                    // `==`, `~=`, `<=`, `>=`: one symbol, so `a == b` never reads as `a = …`.
                    tokens.append(.symbol(String(decoding: units[index...(index + 1)], as: UTF16.self)))
                    index += 2
                } else {
                    tokens.append(.symbol(String(UnicodeScalar(c).map(Character.init) ?? " ")))
                    index += 1
                }
            }
            return tokens
        }

        private static func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        private static func isLetter(_ c: UInt16) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    }

    // MARK: - Reading

    private struct Reader {
        let tokens: [Token]

        /// Opens a block that `end` closes (`while`, `for` and `elseif` don't: their `do`
        /// or `then` belongs to a block already counted).
        private static let openers: Set<String> = ["function", "do", "if", "repeat"]
        private static let closers: Set<String> = ["end", "until"]

        mutating func exports() -> [Member] {
            // The last `return` at the top level is what `require` gets.
            var depth = 0
            var returnAt: Int?
            for (index, token) in tokens.enumerated() {
                guard case .name(let word) = token else { continue }
                if Self.openers.contains(word) { depth += 1 }
                if Self.closers.contains(word) { depth = max(depth - 1, 0) }
                if word == "return", depth == 0 { returnAt = index }
            }
            guard let returnAt, returnAt + 1 < tokens.count else { return [] }
            switch tokens[returnAt + 1] {
            case .symbol("{"):
                return table(at: returnAt + 1).members
            case .name(let name):
                return members(ofTable: name)
            default:
                return []
            }
        }

        /// Everything the module does to the table in `local name`, at the top level.
        private func members(ofTable table: String) -> [Member] {
            var members: [Member] = []
            let functions = localFunctions()
            func add(_ member: Member) {
                if let existing = members.firstIndex(where: { $0.name == member.name }) {
                    members[existing] = member
                } else {
                    members.append(member)
                }
            }
            var depth = 0
            var index = 0
            while index < tokens.count {
                let token = tokens[index]
                if case .name(let word) = token {
                    if depth == 0, word == "local", name(at: index + 1) == table, symbol(at: index + 2) == "=",
                       symbol(at: index + 3) == "{" {
                        // local M = { … }
                        self.table(at: index + 3).members.forEach(add)
                        index = matching(index + 3) + 1
                        continue
                    }
                    if depth == 0, word == "function", name(at: index + 1) == table,
                       let separator = symbol(at: index + 2), separator == "." || separator == ":",
                       let member = self.name(at: index + 3), symbol(at: index + 4) == "(" {
                        // function M.name(…) or function M:name(…)
                        var function = Member(name: member, parameters: parameters(at: index + 4), isMethod: separator == ":")
                        let end = blockEnd(from: index)
                        if isConstructor(from: index, to: end) { function.makes = objectMembers(of: table) }
                        add(function)
                        index = end + 1
                        continue
                    }
                    if depth == 0, word == table, symbol(at: index + 1) == ".", let member = self.name(at: index + 2),
                       symbol(at: index + 3) == "=", !isStatementContinuation(index) {
                        // M.name = value
                        add(value(named: member, at: index + 4, functions: functions))
                        index += 4
                        continue
                    }
                    if Self.openers.contains(word) { depth += 1 }
                    if Self.closers.contains(word) { depth = max(depth - 1, 0) }
                }
                index += 1
            }
            return members
        }

        /// An object made by the module's constructor: its methods, and every `self.x = …`.
        private func objectMembers(of table: String) -> [Member] {
            var members: [Member] = []
            var seen = Set<String>()
            for (index, token) in tokens.enumerated() {
                guard case .name(let word) = token else { continue }
                if word == "function", self.name(at: index + 1) == table, symbol(at: index + 2) == ":",
                   let method = self.name(at: index + 3), seen.insert(method).inserted {
                    members.append(Member(name: method, parameters: parameters(at: index + 4), isMethod: true))
                }
                if word == "self", symbol(at: index + 1) == ".", let field = self.name(at: index + 2),
                   symbol(at: index + 3) == "=", seen.insert(field).inserted {
                    members.append(value(named: field, at: index + 4, functions: [:]))
                }
            }
            return members
        }

        /// A table constructor's named fields: `{ a = 1, b = function(x) … end, c = { … } }`.
        private func table(at open: Int) -> (members: [Member], end: Int) {
            let close = matching(open)
            var members: [Member] = []
            var index = open + 1
            let functions = localFunctions()
            while index < close {
                if let field = name(at: index), symbol(at: index + 1) == "=", symbol(at: index - 1) != "." {
                    let member = value(named: field, at: index + 2, functions: functions)
                    if !members.contains(where: { $0.name == field }) { members.append(member) }
                }
                // On to the next entry, stepping over anything nested.
                if symbol(at: index) == "{" || symbol(at: index) == "(" || symbol(at: index) == "[" {
                    index = matching(index) + 1
                } else if name(at: index) == "function" {
                    index = blockEnd(from: index) + 1
                } else {
                    index += 1
                }
            }
            return (members, close)
        }

        /// What the expression starting at `index` is, as a member called `name`.
        private func value(named name: String, at index: Int, functions: [String: String]) -> Member {
            var member = Member(name: name)
            guard index < tokens.count else { return member }
            switch tokens[index] {
            case .number: member.detail = "number"
            case .string: member.detail = "string"
            case .symbol("{"):
                member.detail = "table"
                member.fields = table(at: index).members
            case .symbol("-"): member.detail = "number"
            case .name("true"), .name("false"): member.detail = "boolean"
            case .name("nil"): member.detail = "nil"
            case .name("function"):
                member.parameters = parameters(at: index + 1)
            case .name(let word):
                if let parameters = functions[word] {
                    member.parameters = parameters
                } else if word.first?.isUppercase == true, symbol(at: index + 1) == "." {
                    member.detail = word            // Vector3.new(…), Color3.fromRGB(…)
                }
            default: break
            }
            return member
        }

        /// `local function name(…)` at the top level, which `M.name = name` hands out.
        private func localFunctions() -> [String: String] {
            var found: [String: String] = [:]
            for index in tokens.indices where name(at: index) == "local" && name(at: index + 1) == "function" {
                if let function = name(at: index + 2), symbol(at: index + 3) == "(" {
                    found[function] = parameters(at: index + 3)
                }
            }
            return found
        }

        /// A constructor sets the object's metatable to the module (or returns `self`).
        private func isConstructor(from start: Int, to end: Int) -> Bool {
            tokens[start...min(end, tokens.count - 1)].contains(.name("setmetatable"))
        }

        /// `a.b = 1` where `a.b` came after something else on the line (`x = a.b = …`
        /// isn't Luau, but `foo(a).b = 1` would look like it).
        private func isStatementContinuation(_ index: Int) -> Bool {
            guard index > 0 else { return false }
            if case .symbol(let s) = tokens[index - 1] { return s == "." || s == ":" }
            return false
        }

        /// The text between a function's parentheses, `(` at `open`.
        private func parameters(at open: Int) -> String {
            guard symbol(at: open) == "(" else { return "" }
            let close = matching(open)
            var words: [String] = []
            for index in (open + 1)..<max(close, open + 1) {
                switch tokens[index] {
                case .name(let word): words.append(word)
                case .symbol("..."): words.append("...")
                case .symbol(","): words.append(",")
                default: break
                }
            }
            // Type annotations (`a: number`) leave their type names in; keep only the
            // name before each comma.
            var names: [String] = []
            var current: String?
            for word in words {
                if word == "," {
                    if let current { names.append(current) }
                    current = nil
                } else if current == nil {
                    current = word
                }
            }
            if let current { names.append(current) }
            return names.joined(separator: ", ")
        }

        /// The `end` of the block a `function`, `do`, `if` or `repeat` at `start` opens.
        private func blockEnd(from start: Int) -> Int {
            var depth = 0
            for index in start..<tokens.count {
                guard case .name(let word) = tokens[index] else { continue }
                if Self.openers.contains(word) { depth += 1 }
                if Self.closers.contains(word) {
                    depth -= 1
                    if depth == 0 { return index }
                }
            }
            return tokens.count - 1
        }

        /// The bracket closing the one at `open`.
        private func matching(_ open: Int) -> Int {
            guard case .symbol(let opening) = tokens[open] else { return open }
            let closing = opening == "{" ? "}" : opening == "(" ? ")" : "]"
            var depth = 0
            for index in open..<tokens.count {
                if case .symbol(let s) = tokens[index] {
                    if s == opening { depth += 1 }
                    if s == closing {
                        depth -= 1
                        if depth == 0 { return index }
                    }
                }
            }
            return tokens.count - 1
        }

        private func name(at index: Int) -> String? {
            guard index >= 0, index < tokens.count, case .name(let word) = tokens[index] else { return nil }
            return word
        }

        private func symbol(at index: Int) -> String? {
            guard index >= 0, index < tokens.count, case .symbol(let s) = tokens[index] else { return nil }
            return s
        }
    }
}
