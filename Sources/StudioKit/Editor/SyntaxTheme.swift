import AppKit

/// Which language a code editor is showing.
enum CodeLanguage {
    case luau
    case wren
    case metal

    init(_ language: ScriptLanguage) {
        self = language == .luau ? .luau : .wren
    }

    func tokenize(_ text: String) -> [SyntaxToken] {
        switch self {
        case .luau: return LuauSyntax.tokenize(text)
        case .wren: return WrenSyntax.tokenize(text)
        case .metal: return MetalSyntax.tokenize(text)
        }
    }

    func isInCommentOrString(offset: Int, in text: String) -> Bool {
        switch self {
        case .luau: return LuauSyntax.isInCommentOrString(offset: offset, in: text)
        case .wren: return WrenSyntax.isInCommentOrString(offset: offset, in: text)
        case .metal: return MetalSyntax.isInCommentOrString(offset: offset, in: text)
        }
    }

    func completions(in text: String, caret: Int) -> [CompletionItem] {
        switch self {
        case .luau: return LuauCompletion.items(in: text, caret: caret)
        case .wren: return WrenCompletion.items(in: text, caret: caret)
        case .metal: return MetalCompletion.items(in: text, caret: caret)
        }
    }

    /// Roblox Studio indents Luau with tabs; Wren and Metal use spaces here.
    var indentUnit: String {
        self == .luau ? "\t" : "  "
    }
}

/// Colours for highlighted Wren, tuned for the dark editor background.
enum SyntaxTheme {
    static let plain = NSColor(srgbRed: 0.88, green: 0.89, blue: 0.91, alpha: 1)
    static let keyword = NSColor(srgbRed: 0.82, green: 0.58, blue: 0.94, alpha: 1)
    static let type = NSColor(srgbRed: 0.46, green: 0.82, blue: 0.80, alpha: 1)
    static let field = NSColor(srgbRed: 0.93, green: 0.62, blue: 0.48, alpha: 1)
    static let number = NSColor(srgbRed: 0.91, green: 0.77, blue: 0.46, alpha: 1)
    static let string = NSColor(srgbRed: 0.62, green: 0.82, blue: 0.53, alpha: 1)
    static let escape = NSColor(srgbRed: 0.45, green: 0.75, blue: 0.72, alpha: 1)
    static let interpolation = NSColor(srgbRed: 0.40, green: 0.68, blue: 0.62, alpha: 1)
    static let comment = NSColor(srgbRed: 0.44, green: 0.49, blue: 0.53, alpha: 1)
    static let attribute = NSColor(srgbRed: 0.70, green: 0.66, blue: 0.50, alpha: 1)
    static let punctuation = NSColor(srgbRed: 0.65, green: 0.68, blue: 0.73, alpha: 1)

    static func color(for kind: SyntaxTokenKind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .type: return type
        case .field: return field
        case .number: return number
        case .string: return string
        case .escape: return escape
        case .interpolation: return interpolation
        case .comment: return comment
        case .attribute: return attribute
        case .punctuation: return punctuation
        case .identifier: return plain
        }
    }

    /// Repaints a text storage from scratch.
    ///
    /// Scripts are small, so a full re-tokenise per keystroke is cheaper than tracking
    /// dirty ranges — and correct, which incremental highlighting of nested block
    /// comments and multi-line strings is not.
    static func highlight(_ storage: NSTextStorage, baseFont: NSFont,
                          language: CodeLanguage = .luau) {
        let text = storage.string
        let length = (text as NSString).length
        guard length < 400_000 else { return }

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: plain],
                              range: NSRange(location: 0, length: length))
        for token in language.tokenize(text) where token.kind != .identifier {
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        storage.endEditing()
    }
}
