import Foundation

/// A lexer for Luau, used to highlight the script editor and to tell whether the
/// caret sits in a comment or string, where completions should stay quiet.
///
/// Covers what Luau adds to Lua: backtick strings with `{expression}` interpolation
/// (the code inside the braces is lexed as code), `//` floor division, compound
/// assignment, and `continue`. Long brackets — `[[ ]]`, `[==[ ]==]` — are matched
/// by level, in strings and in `--[[ ]]` comments alike.
enum LuauSyntax {

    static let keywords: Set<String> = [
        "and", "break", "continue", "do", "else", "elseif", "end", "false", "for",
        "function", "if", "in", "local", "nil", "not", "or", "repeat", "return",
        "then", "true", "until", "while"
    ]

    /// Globals scripts use constantly, coloured like types so they stand out.
    static let knownGlobals: Set<String> = [
        "game", "workspace", "Workspace", "script", "shared", "task", "math", "string",
        "table", "coroutine", "buffer", "bit32", "utf8", "os", "debug"
    ]

    static func tokenize(_ text: String) -> [SyntaxToken] {
        var lexer = Lexer(units: Array(text.utf16))
        lexer.run()
        return lexer.tokens
    }

    static func isInCommentOrString(offset: Int, in text: String) -> Bool {
        for token in tokenize(text) {
            let start = token.range.location
            let end = start + token.range.length
            guard offset >= start, offset <= end else { continue }
            switch token.kind {
            case .comment, .string, .escape:
                // The caret just after a closed string is back in code.
                if offset == end, token.kind == .string, end > start {
                    let units = Array(text.utf16)
                    let last = units[end - 1]
                    if last == Ch.quote || last == Ch.apostrophe || last == Ch.backtick || last == Ch.rightBracket {
                        continue
                    }
                }
                return true
            default:
                continue
            }
        }
        return false
    }

    // MARK: - Lexer

    private struct Lexer {
        let units: [UInt16]
        var index = 0
        var tokens: [SyntaxToken] = []

        init(units: [UInt16]) {
            self.units = units
            tokens.reserveCapacity(units.count / 4)
        }

        mutating func run() {
            while index < units.count { lexOne() }
        }

        private mutating func lexOne() {
            let c = units[index]
            if isSpace(c) { index += 1; return }
            if c == Ch.minus, peek(1) == Ch.minus { comment(); return }
            if c == Ch.quote || c == Ch.apostrophe { quotedString(c); return }
            if c == Ch.backtick { interpolatedString(); return }
            if c == Ch.leftBracket, let level = longBracketLevel(at: index) {
                longString(level: level)
                return
            }
            if isDigit(c) || (c == Ch.dot && isDigit(peek(1))) { number(); return }
            if isAlpha(c) || c == Ch.underscore { identifier(); return }
            single(.punctuation)
        }

        // MARK: Comments

        private mutating func comment() {
            let start = index
            index += 2
            if index < units.count, units[index] == Ch.leftBracket, let level = longBracketLevel(at: index) {
                index = skipLongBracket(from: index, level: level)
                emit(start, index, .comment)
                return
            }
            while index < units.count, units[index] != Ch.newline { index += 1 }
            emit(start, index, .comment)
        }

        // MARK: Strings

        private mutating func quotedString(_ quote: UInt16) {
            var segmentStart = index
            index += 1
            while index < units.count {
                let c = units[index]
                if c == Ch.backslash {
                    emit(segmentStart, index, .string)
                    let escapeStart = index
                    index = min(index + 2, units.count)
                    emit(escapeStart, index, .escape)
                    segmentStart = index
                    continue
                }
                if c == quote {
                    index += 1
                    break
                }
                if c == Ch.newline { break }          // unterminated: stop at the line end
                index += 1
            }
            emit(segmentStart, index, .string)
        }

        /// `` `text {expression} text` `` — the braces are delimiters and the code
        /// inside them is lexed as ordinary Luau.
        private mutating func interpolatedString() {
            var segmentStart = index
            index += 1
            while index < units.count {
                let c = units[index]
                if c == Ch.backslash {
                    emit(segmentStart, index, .string)
                    let escapeStart = index
                    index = min(index + 2, units.count)
                    emit(escapeStart, index, .escape)
                    segmentStart = index
                    continue
                }
                if c == Ch.leftBrace {
                    emit(segmentStart, index, .string)
                    single(.interpolation)
                    interpolation()
                    segmentStart = index
                    continue
                }
                if c == Ch.backtick {
                    index += 1
                    break
                }
                index += 1
            }
            emit(segmentStart, index, .string)
        }

        private mutating func interpolation() {
            var depth = 1
            while index < units.count {
                let c = units[index]
                if c == Ch.leftBrace {
                    depth += 1
                    single(.punctuation)
                    continue
                }
                if c == Ch.rightBrace {
                    depth -= 1
                    single(depth == 0 ? .interpolation : .punctuation)
                    if depth == 0 { return }
                    continue
                }
                lexOne()
            }
        }

        private mutating func longString(level: Int) {
            let start = index
            index = skipLongBracket(from: index, level: level)
            emit(start, index, .string)
        }

        /// `[`, `level` equals signs, `[` — or nil if this is not a long bracket.
        private func longBracketLevel(at position: Int) -> Int? {
            guard position < units.count, units[position] == Ch.leftBracket else { return nil }
            var cursor = position + 1
            var level = 0
            while cursor < units.count, units[cursor] == Ch.equals {
                level += 1
                cursor += 1
            }
            guard cursor < units.count, units[cursor] == Ch.leftBracket else { return nil }
            return level
        }

        /// Returns the index just past the matching `]==]`, or the end of the text.
        private func skipLongBracket(from position: Int, level: Int) -> Int {
            var cursor = position + level + 2
            while cursor < units.count {
                if units[cursor] == Ch.rightBracket {
                    var probe = cursor + 1
                    var equals = 0
                    while probe < units.count, units[probe] == Ch.equals {
                        equals += 1
                        probe += 1
                    }
                    if equals == level, probe < units.count, units[probe] == Ch.rightBracket {
                        return probe + 1
                    }
                }
                cursor += 1
            }
            return units.count
        }

        // MARK: Numbers and names

        private mutating func number() {
            let start = index
            if units[index] == Ch.zero, index + 1 < units.count {
                let marker = units[index + 1]
                if marker == Ch.lowerX || marker == Ch.upperX {
                    index += 2
                    while index < units.count, isHexDigit(units[index]) || units[index] == Ch.underscore { index += 1 }
                    emit(start, index, .number)
                    return
                }
                if marker == Ch.lowerB || marker == Ch.upperB {
                    index += 2
                    while index < units.count,
                          units[index] == Ch.zero || units[index] == Ch.one || units[index] == Ch.underscore { index += 1 }
                    emit(start, index, .number)
                    return
                }
            }
            while index < units.count, isDigit(units[index]) || units[index] == Ch.underscore { index += 1 }
            if index < units.count, units[index] == Ch.dot, peek(1) != Ch.dot {
                index += 1
                while index < units.count, isDigit(units[index]) || units[index] == Ch.underscore { index += 1 }
            }
            if index < units.count, units[index] == Ch.lowerE || units[index] == Ch.upperE {
                let save = index
                index += 1
                if index < units.count, units[index] == Ch.plus || units[index] == Ch.minus { index += 1 }
                if index < units.count, isDigit(units[index]) {
                    while index < units.count, isDigit(units[index]) { index += 1 }
                } else {
                    index = save
                }
            }
            emit(start, index, .number)
        }

        private mutating func identifier() {
            let start = index
            while index < units.count, isIdentifier(units[index]) { index += 1 }
            let word = String(decoding: units[start..<index], as: UTF16.self)
            let kind: SyntaxTokenKind
            if LuauSyntax.keywords.contains(word) {
                kind = .keyword
            } else if LuauSyntax.knownGlobals.contains(word) {
                kind = .type
            } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                kind = .type
            } else {
                kind = .identifier
            }
            emit(start, index, kind)
        }

        // MARK: Helpers

        private mutating func single(_ kind: SyntaxTokenKind) {
            let start = index
            index += 1
            emit(start, index, kind)
        }

        private mutating func emit(_ start: Int, _ end: Int, _ kind: SyntaxTokenKind) {
            guard end > start else { return }
            tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind))
        }

        private func peek(_ offset: Int) -> UInt16 {
            let position = index + offset
            return position < units.count ? units[position] : 0
        }

        private func isSpace(_ c: UInt16) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
        private func isHexDigit(_ c: UInt16) -> Bool { isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70) }
        private func isAlpha(_ c: UInt16) -> Bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) }
        private func isIdentifier(_ c: UInt16) -> Bool { isAlpha(c) || isDigit(c) || c == Ch.underscore }
    }

    fileprivate enum Ch {
        static let minus = UInt16(UInt8(ascii: "-"))
        static let plus = UInt16(UInt8(ascii: "+"))
        static let quote = UInt16(UInt8(ascii: "\""))
        static let apostrophe = UInt16(UInt8(ascii: "'"))
        static let backtick = UInt16(UInt8(ascii: "`"))
        static let backslash = UInt16(UInt8(ascii: "\\"))
        static let leftBracket = UInt16(UInt8(ascii: "["))
        static let rightBracket = UInt16(UInt8(ascii: "]"))
        static let leftBrace = UInt16(UInt8(ascii: "{"))
        static let rightBrace = UInt16(UInt8(ascii: "}"))
        static let equals = UInt16(UInt8(ascii: "="))
        static let underscore = UInt16(UInt8(ascii: "_"))
        static let newline = UInt16(UInt8(ascii: "\n"))
        static let dot = UInt16(UInt8(ascii: "."))
        static let zero = UInt16(UInt8(ascii: "0"))
        static let one = UInt16(UInt8(ascii: "1"))
        static let lowerX = UInt16(UInt8(ascii: "x"))
        static let upperX = UInt16(UInt8(ascii: "X"))
        static let lowerB = UInt16(UInt8(ascii: "b"))
        static let upperB = UInt16(UInt8(ascii: "B"))
        static let lowerE = UInt16(UInt8(ascii: "e"))
        static let upperE = UInt16(UInt8(ascii: "E"))
    }
}
