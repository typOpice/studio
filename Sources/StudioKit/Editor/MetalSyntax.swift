import Foundation

/// A lexer for the Metal Shading Language, used to highlight the shader editor and to
/// sanity-check a shader body before handing it to the compiler.
///
/// MSL is C++, so unlike Wren its block comments do not nest and its type names are
/// lowercase — they are recognised from a list rather than by capitalisation.
enum MetalSyntax {

    static let keywords: Set<String> = [
        "break", "case", "const", "constant", "continue", "default", "device", "do",
        "else", "enum", "false", "for", "fragment", "if", "inline", "kernel",
        "namespace", "return", "sizeof", "static", "struct", "switch", "template",
        "threadgroup", "true", "typedef", "union", "using", "vertex", "void", "while",
        "auto", "class", "public", "private", "thread"
    ]

    static let types: Set<String> = {
        var names: Set<String> = ["void", "bool", "char", "short", "int", "uint", "long",
                                  "size_t", "sampler", "texture2d", "texture3d", "texturecube",
                                  "array", "atomic"]
        for scalar in ["float", "half", "int", "uint", "short", "char", "bool"] {
            names.insert(scalar)
            for n in 2...4 { names.insert("\(scalar)\(n)") }
        }
        for rows in 2...4 {
            for columns in 2...4 {
                names.insert("float\(rows)x\(columns)")
                names.insert("half\(rows)x\(columns)")
            }
        }
        return names
    }()

    /// Functions worth suggesting in the editor.
    static let builtins: [String] = [
        "abs", "acos", "asin", "atan", "atan2", "ceil", "clamp", "cos", "cosh", "cross",
        "degrees", "distance", "dot", "exp", "exp2", "faceforward", "floor", "fma",
        "fmod", "fract", "length", "log", "log2", "max", "min", "mix", "normalize",
        "pow", "radians", "reflect", "refract", "round", "rsqrt", "saturate", "sign",
        "sin", "sinh", "smoothstep", "sqrt", "step", "tan", "tanh", "trunc"
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
            if token.kind == .comment || token.kind == .string || token.kind == .escape {
                return true
            }
        }
        return false
    }

    /// The source with comments and string literals blanked out, for cheap checks.
    static func codeOnly(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for token in tokenize(text) where token.kind == .comment || token.kind == .string {
            if token.range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: token.range.location - cursor))
            }
            result += " "
            cursor = token.range.location + token.range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
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
            if c == Ch.slash, peek(1) == Ch.slash { lineComment(); return }
            if c == Ch.slash, peek(1) == Ch.star { blockComment(); return }
            if c == Ch.quote { stringLiteral(); return }
            if c == Ch.hash { directive(); return }
            if isDigit(c) { number(); return }
            if isAlpha(c) || c == Ch.underscore { identifier(); return }
            single(.punctuation)
        }

        private mutating func lineComment() {
            let start = index
            while index < units.count, units[index] != Ch.newline { index += 1 }
            emit(start, index, .comment)
        }

        /// C++ block comments do not nest.
        private mutating func blockComment() {
            let start = index
            index += 2
            while index < units.count {
                if units[index] == Ch.star, peek(1) == Ch.slash {
                    index += 2
                    break
                }
                index += 1
            }
            emit(start, index, .comment)
        }

        private mutating func stringLiteral() {
            let start = index
            index += 1
            while index < units.count {
                if units[index] == Ch.backslash { index = min(index + 2, units.count); continue }
                if units[index] == Ch.quote { index += 1; break }
                if units[index] == Ch.newline { break }
                index += 1
            }
            emit(start, index, .string)
        }

        private mutating func directive() {
            let start = index
            while index < units.count, units[index] != Ch.newline { index += 1 }
            emit(start, index, .attribute)
        }

        private mutating func number() {
            let start = index
            if units[index] == Ch.zero, peek(1) == Ch.lowerX || peek(1) == Ch.upperX {
                index += 2
                while index < units.count, isHexDigit(units[index]) { index += 1 }
                emit(start, index, .number)
                return
            }
            while index < units.count, isDigit(units[index]) { index += 1 }
            if index < units.count, units[index] == Ch.dot {
                index += 1
                while index < units.count, isDigit(units[index]) { index += 1 }
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
            // Trailing f / h / u suffixes.
            if index < units.count, isSuffix(units[index]) { index += 1 }
            emit(start, index, .number)
        }

        private mutating func identifier() {
            let start = index
            while index < units.count, isIdentifier(units[index]) { index += 1 }
            let word = String(decoding: units[start..<index], as: UTF16.self)
            let kind: SyntaxTokenKind
            if MetalSyntax.keywords.contains(word) {
                kind = .keyword
            } else if MetalSyntax.types.contains(word) {
                kind = .type
            } else {
                kind = .identifier
            }
            emit(start, index, kind)
        }

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
        private func isHexDigit(_ c: UInt16) -> Bool {
            isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
        }
        private func isAlpha(_ c: UInt16) -> Bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) }
        private func isIdentifier(_ c: UInt16) -> Bool { isAlpha(c) || isDigit(c) || c == Ch.underscore }
        private func isSuffix(_ c: UInt16) -> Bool {
            c == Ch.lowerF || c == Ch.lowerH || c == Ch.lowerU
        }
    }

    private enum Ch {
        static let slash = UInt16(UInt8(ascii: "/"))
        static let star = UInt16(UInt8(ascii: "*"))
        static let quote = UInt16(UInt8(ascii: "\""))
        static let backslash = UInt16(UInt8(ascii: "\\"))
        static let underscore = UInt16(UInt8(ascii: "_"))
        static let hash = UInt16(UInt8(ascii: "#"))
        static let newline = UInt16(UInt8(ascii: "\n"))
        static let dot = UInt16(UInt8(ascii: "."))
        static let zero = UInt16(UInt8(ascii: "0"))
        static let lowerX = UInt16(UInt8(ascii: "x"))
        static let upperX = UInt16(UInt8(ascii: "X"))
        static let lowerE = UInt16(UInt8(ascii: "e"))
        static let upperE = UInt16(UInt8(ascii: "E"))
        static let lowerF = UInt16(UInt8(ascii: "f"))
        static let lowerH = UInt16(UInt8(ascii: "h"))
        static let lowerU = UInt16(UInt8(ascii: "u"))
        static let plus = UInt16(UInt8(ascii: "+"))
        static let minus = UInt16(UInt8(ascii: "-"))
    }
}
