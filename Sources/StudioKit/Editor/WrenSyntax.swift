import Foundation

enum SyntaxTokenKind: Equatable {
    case keyword
    case type          // Capitalised identifier — a class by Wren convention
    case field         // _instanceField or __staticField
    case number
    case string
    case escape        // \n, \" inside a string
    case interpolation // the %( ) delimiters around an interpolated expression
    case comment
    case attribute     // #attribute lines
    case punctuation
    case identifier
}

struct SyntaxToken: Equatable {
    var range: NSRange
    var kind: SyntaxTokenKind
}

/// A lexer for Wren, used for syntax highlighting and to tell whether the caret sits
/// inside a comment or string (where completions should stay out of the way).
///
/// Works in UTF-16 units so token ranges drop straight into `NSAttributedString`.
enum WrenSyntax {

    static let keywords: Set<String> = [
        "as", "break", "class", "construct", "continue", "else", "false", "for",
        "foreign", "if", "import", "in", "is", "null", "return", "static", "super",
        "this", "true", "var", "while"
    ]

    static func tokenize(_ text: String) -> [SyntaxToken] {
        var lexer = Lexer(units: Array(text.utf16))
        lexer.run()
        return lexer.tokens
    }

    /// The token covering a UTF-16 offset, if any.
    static func token(at offset: Int, in text: String) -> SyntaxToken? {
        tokenize(text).first { NSLocationInRange(offset, $0.range) }
    }

    /// True when the offset is somewhere the user is writing prose, not code.
    static func isInCommentOrString(offset: Int, in text: String) -> Bool {
        for token in tokenize(text) {
            let start = token.range.location
            let end = start + token.range.length
            // Treat the position just past a token's end as still inside it, so typing
            // at the tail of a comment is recognised.
            guard offset >= start, offset <= end else { continue }
            switch token.kind {
            case .comment, .string, .escape:
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
            while index < units.count {
                lexOne()
            }
        }

        private mutating func lexOne() {
            let c = units[index]
            if isSpace(c) { index += 1; return }
            if c == Ch.slash, peek(1) == Ch.slash { lineComment(); return }
            if c == Ch.slash, peek(1) == Ch.star { blockComment(); return }
            if c == Ch.quote { stringLiteral(); return }
            if isDigit(c) { number(); return }
            if c == Ch.underscore { field(); return }
            if isAlpha(c) { identifier(); return }
            if c == Ch.hash { attribute(); return }
            single(.punctuation)
        }

        // MARK: Pieces

        private mutating func lineComment() {
            let start = index
            while index < units.count, units[index] != Ch.newline { index += 1 }
            emit(start, index, .comment)
        }

        /// Wren block comments nest, so track the depth rather than stopping at the first `*/`.
        private mutating func blockComment() {
            let start = index
            index += 2
            var depth = 1
            while index < units.count, depth > 0 {
                if units[index] == Ch.slash, peek(1) == Ch.star {
                    depth += 1
                    index += 2
                } else if units[index] == Ch.star, peek(1) == Ch.slash {
                    depth -= 1
                    index += 2
                } else {
                    index += 1
                }
            }
            emit(start, index, .comment)
        }

        private mutating func stringLiteral() {
            if peek(1) == Ch.quote, peek(2) == Ch.quote {
                rawString()
                return
            }
            var segmentStart = index
            index += 1                                   // opening quote

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
                if c == Ch.percent, peek(1) == Ch.leftParen {
                    emit(segmentStart, index, .string)
                    let delimiterStart = index
                    index += 2
                    emit(delimiterStart, index, .interpolation)
                    interpolation()
                    segmentStart = index
                    continue
                }
                if c == Ch.quote {
                    index += 1
                    emit(segmentStart, index, .string)
                    return
                }
                index += 1
            }
            emit(segmentStart, index, .string)           // unterminated
        }

        private mutating func rawString() {
            let start = index
            index += 3
            while index < units.count {
                if units[index] == Ch.quote, peek(1) == Ch.quote, peek(2) == Ch.quote {
                    index += 3
                    break
                }
                index += 1
            }
            emit(start, index, .string)
        }

        /// Lexes the code inside `%( ... )` as ordinary Wren until the parens balance.
        private mutating func interpolation() {
            var depth = 1
            while index < units.count {
                let c = units[index]
                if c == Ch.leftParen {
                    depth += 1
                    single(.punctuation)
                    continue
                }
                if c == Ch.rightParen {
                    depth -= 1
                    single(depth == 0 ? .interpolation : .punctuation)
                    if depth == 0 { return }
                    continue
                }
                lexOne()
            }
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
            if index < units.count, units[index] == Ch.dot, isDigit(peek(1)) {
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
            emit(start, index, .number)
        }

        private mutating func field() {
            let start = index
            while index < units.count, isIdentifier(units[index]) { index += 1 }
            emit(start, index, .field)
        }

        private mutating func identifier() {
            let start = index
            while index < units.count, isIdentifier(units[index]) { index += 1 }
            let word = String(decoding: units[start..<index], as: UTF16.self)
            let kind: SyntaxTokenKind
            if WrenSyntax.keywords.contains(word) {
                kind = .keyword
            } else if let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) {
                kind = .type
            } else {
                kind = .identifier
            }
            emit(start, index, kind)
        }

        private mutating func attribute() {
            let start = index
            while index < units.count, units[index] != Ch.newline { index += 1 }
            emit(start, index, .attribute)
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
        private func isHexDigit(_ c: UInt16) -> Bool {
            isDigit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
        }
        private func isAlpha(_ c: UInt16) -> Bool {
            (c >= 97 && c <= 122) || (c >= 65 && c <= 90)
        }
        private func isIdentifier(_ c: UInt16) -> Bool { isAlpha(c) || isDigit(c) || c == Ch.underscore }
    }

    private enum Ch {
        static let slash = UInt16(UInt8(ascii: "/"))
        static let star = UInt16(UInt8(ascii: "*"))
        static let quote = UInt16(UInt8(ascii: "\""))
        static let backslash = UInt16(UInt8(ascii: "\\"))
        static let percent = UInt16(UInt8(ascii: "%"))
        static let leftParen = UInt16(UInt8(ascii: "("))
        static let rightParen = UInt16(UInt8(ascii: ")"))
        static let underscore = UInt16(UInt8(ascii: "_"))
        static let hash = UInt16(UInt8(ascii: "#"))
        static let newline = UInt16(UInt8(ascii: "\n"))
        static let dot = UInt16(UInt8(ascii: "."))
        static let zero = UInt16(UInt8(ascii: "0"))
        static let lowerX = UInt16(UInt8(ascii: "x"))
        static let upperX = UInt16(UInt8(ascii: "X"))
        static let lowerE = UInt16(UInt8(ascii: "e"))
        static let upperE = UInt16(UInt8(ascii: "E"))
        static let plus = UInt16(UInt8(ascii: "+"))
        static let minus = UInt16(UInt8(ascii: "-"))
    }
}
