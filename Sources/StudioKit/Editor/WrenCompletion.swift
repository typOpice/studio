import Foundation

/// Works out what to offer at the caret.
///
/// Two modes. After a dot it resolves the type of the expression to the left and lists
/// that type's members — walking chains like `Workspace.find("Orb").position.` by
/// following each member's return type. Otherwise it offers keywords, known classes and
/// the symbols declared in the document so far.
///
/// Pure functions over `(source, caret)`, which is what makes it testable without a UI.
enum WrenCompletion {

    /// What a resolved receiver turned out to be.
    enum Context: Equatable {
        case staticClass(String)   // `Workspace.` — class-level members
        case instance(String)      // `part.` — instance members of that type
    }

    private struct Segment {
        var name: String
        var isCall = false
        var isSubscripted = false
    }

    private static let maximumItems = 60

    // MARK: - Entry points

    /// The identifier characters immediately before the caret, which a chosen
    /// completion replaces. Empty right after a dot.
    static func partialWordRange(in text: String, caret: Int) -> NSRange {
        let units = Array(text.utf16)
        let end = min(max(caret, 0), units.count)
        var start = end
        while start > 0, isIdentifier(units[start - 1]) { start -= 1 }
        return NSRange(location: start, length: end - start)
    }

    static func items(in text: String, caret: Int) -> [CompletionItem] {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)

        // Never interrupt someone writing a comment or a string literal.
        if WrenSyntax.isInCommentOrString(offset: caret, in: text) { return [] }

        let wordRange = partialWordRange(in: text, caret: caret)
        let prefix = String(decoding: units[wordRange.location..<(wordRange.location + wordRange.length)],
                            as: UTF16.self)

        // Member completion when a dot sits immediately before the partial word.
        if wordRange.location > 0, units[wordRange.location - 1] == dot {
            let candidates = memberItems(units: units, dotIndex: wordRange.location - 1, text: text)
            return rank(candidates, prefix: prefix)
        }

        return rank(globalItems(units: units, caret: caret, text: text), prefix: prefix)
    }

    // MARK: - Member completion

    private static func memberItems(units: [UInt16], dotIndex: Int, text: String) -> [CompletionItem] {
        guard let segments = receiverChain(units: units, before: dotIndex) else { return [] }
        guard let context = resolve(segments: segments, units: units, text: text, visiting: []) else { return [] }
        switch context {
        case .staticClass(let name):
            return WrenAPI.members(ofStatic: name)
        case .instance(let type):
            return WrenAPI.members(ofInstance: type)
        }
    }

    /// Reads an expression backwards from a dot: `a.b(x).c[0]` → segments a, b, c.
    private static func receiverChain(units: [UInt16], before dotIndex: Int) -> [Segment]? {
        var index = dotIndex
        var segments: [Segment] = []

        while true {
            index = skipSpacesBackwards(units, from: index)
            guard index > 0 else { return nil }

            var segment = Segment(name: "")

            if units[index - 1] == rightBracket {
                guard let open = matchBackwards(units, from: index - 1, open: leftBracket, close: rightBracket)
                else { return nil }
                segment.isSubscripted = true
                index = open
                index = skipSpacesBackwards(units, from: index)
                guard index > 0 else { return nil }
            }

            if units[index - 1] == rightParen {
                guard let open = matchBackwards(units, from: index - 1, open: leftParen, close: rightParen)
                else { return nil }
                segment.isCall = true
                index = open
                index = skipSpacesBackwards(units, from: index)
                guard index > 0 else { return nil }
            }

            // A literal receiver, e.g. `"text".` or `(1 + 2).`
            if units[index - 1] == quote {
                segments.insert(Segment(name: "\"", isCall: false), at: 0)
                return segments
            }

            var start = index
            while start > 0, isIdentifier(units[start - 1]) { start -= 1 }
            guard start < index else { return nil }

            segment.name = String(decoding: units[start..<index], as: UTF16.self)
            segments.insert(segment, at: 0)

            index = skipSpacesBackwards(units, from: start)
            if index > 0, units[index - 1] == dot {
                index -= 1
                continue
            }
            return segments
        }
    }

    private static func resolve(segments: [Segment], units: [UInt16], text: String,
                                visiting: Set<String>) -> Context? {
        guard let head = segments.first else { return nil }

        var context: Context
        if head.name == "\"" {
            context = .instance("String")
        } else if let local = localType(of: head.name, units: units, text: text, visiting: visiting) {
            context = .instance(local)
        } else if WrenAPI.isKnownType(head.name) {
            // `Vec3.new(...)` is a call on the class and yields an instance.
            if head.isCall || head.isSubscripted {
                context = .instance(head.name)
            } else {
                context = .staticClass(head.name)
            }
        } else if head.name == "script" {
            context = .instance("Script")
        } else if head.name == "this" {
            return nil
        } else {
            return nil
        }

        if head.isSubscripted, case .instance(let type) = context, let element = WrenAPI.elementType(of: type) {
            context = .instance(element)
        }

        for segment in segments.dropFirst() {
            guard let member = member(named: segment.name, in: context) else { return nil }
            guard var returns = member.returns else { return nil }
            if segment.isSubscripted, let element = WrenAPI.elementType(of: returns) {
                returns = element
            }
            context = .instance(returns)
        }

        return context
    }

    private static func member(named name: String, in context: Context) -> CompletionItem? {
        let candidates: [CompletionItem]
        switch context {
        case .staticClass(let className): candidates = WrenAPI.members(ofStatic: className)
        case .instance(let type): candidates = WrenAPI.members(ofInstance: type)
        }
        // Prefer an exact name match; several overloads share one name.
        return candidates.first { $0.label == name || $0.label.hasPrefix("\(name)(") }
    }

    // MARK: - Local variables

    /// Infers the type of a `var` declared earlier in the document.
    private static func localType(of name: String, units: [UInt16], text: String,
                                  visiting: Set<String>) -> String? {
        guard !visiting.contains(name) else { return nil }
        guard let expression = lastAssignment(to: name, in: text) else { return nil }
        return type(ofExpression: expression, units: units, text: text,
                    visiting: visiting.union([name]))
    }

    /// The right-hand side of the last `var name = ...` in the document.
    private static func lastAssignment(to name: String, in text: String) -> String? {
        var result: String?
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("var ") else { continue }
            let body = trimmed.dropFirst(4)
            guard let equals = body.firstIndex(of: "=") else { continue }
            let declared = body[body.startIndex..<equals].trimmingCharacters(in: .whitespaces)
            guard declared == name else { continue }
            let value = body[body.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !value.isEmpty { result = value }
        }
        return result
    }

    /// Types an expression written left to right, e.g. `Workspace.find("Orb").position`.
    private static func type(ofExpression expression: String, units: [UInt16], text: String,
                             visiting: Set<String>) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }

        if first == "\"" { return "String" }
        if first.isNumber { return "Num" }
        if first == "[" { return "List" }
        if trimmed == "true" || trimmed == "false" { return "Bool" }
        if trimmed == "null" { return nil }

        // Reuse the backward parser by appending a dot and reading the chain before it.
        let probe = Array((trimmed + ".").utf16)
        guard let segments = receiverChain(units: probe, before: probe.count - 1) else { return nil }
        guard let context = resolve(segments: segments, units: probe, text: text, visiting: visiting) else {
            return nil
        }
        switch context {
        case .instance(let type): return type
        case .staticClass(let name): return name
        }
    }

    // MARK: - Global completion

    private static func globalItems(units: [UInt16], caret: Int, text: String) -> [CompletionItem] {
        var items: [CompletionItem] = []

        for keyword in WrenSyntax.keywords.sorted() {
            items.append(CompletionItem(label: keyword, insert: keyword,
                                        detail: "keyword", kind: .keyword, returns: nil))
        }

        for (name, origin) in WrenAPI.globalTypes {
            items.append(CompletionItem(label: name, insert: name,
                                        detail: origin == "core" ? "class" : "\(origin) class",
                                        kind: .type, returns: nil))
        }

        items.append(contentsOf: WrenAPI.snippets)

        // Symbols the document itself declares, typed where we can work it out.
        let visible = String(decoding: units[0..<min(caret, units.count)], as: UTF16.self)
        for name in declaredVariables(in: visible) {
            let type = localType(of: name, units: units, text: text, visiting: [])
            items.append(CompletionItem(label: name, insert: name,
                                        detail: type ?? "variable", kind: .variable, returns: type))
        }
        for name in declaredClasses(in: text) {
            items.append(CompletionItem(label: name, insert: name,
                                        detail: "class", kind: .type, returns: nil))
        }
        return items
    }

    static func declaredVariables(in text: String) -> [String] {
        var names: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("var ") {
                let body = trimmed.dropFirst(4)
                let name = body.prefix { isIdentifierCharacter($0) }
                if !name.isEmpty { names.append(String(name)) }
            }
            // Block parameters: `{ |dt| ... }`
            if let open = line.firstIndex(of: "|") {
                let rest = line[line.index(after: open)...]
                if let close = rest.firstIndex(of: "|") {
                    for piece in rest[rest.startIndex..<close].components(separatedBy: ",") {
                        let name = piece.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty, name.allSatisfy(isIdentifierCharacter) { names.append(name) }
                    }
                }
            }
        }
        return Array(Set(names)).sorted()
    }

    static func declaredClasses(in text: String) -> [String] {
        var names: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("class ") else { continue }
            let name = trimmed.dropFirst(6).prefix { isIdentifierCharacter($0) }
            if !name.isEmpty { names.append(String(name)) }
        }
        return Array(Set(names)).sorted()
    }

    // MARK: - Ranking

    private static func rank(_ items: [CompletionItem], prefix: String) -> [CompletionItem] {
        let lowered = prefix.lowercased()
        var seen: Set<String> = []
        let matched = items.filter { item in
            guard lowered.isEmpty || item.label.lowercased().hasPrefix(lowered) else { return false }
            return seen.insert(item.label).inserted
        }
        return Array(matched.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }.prefix(maximumItems))
    }

    // MARK: - Character helpers

    private static let dot = UInt16(UInt8(ascii: "."))
    private static let quote = UInt16(UInt8(ascii: "\""))
    private static let leftParen = UInt16(UInt8(ascii: "("))
    private static let rightParen = UInt16(UInt8(ascii: ")"))
    private static let leftBracket = UInt16(UInt8(ascii: "["))
    private static let rightBracket = UInt16(UInt8(ascii: "]"))
    private static let space = UInt16(UInt8(ascii: " "))
    private static let tab = UInt16(9)

    private static func isIdentifier(_ c: UInt16) -> Bool {
        (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57)
            || c == UInt16(UInt8(ascii: "_"))
    }

    private static func isIdentifierCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    private static func skipSpacesBackwards(_ units: [UInt16], from index: Int) -> Int {
        var index = index
        while index > 0, units[index - 1] == space || units[index - 1] == tab { index -= 1 }
        return index
    }

    /// Index just after the matching open bracket, scanning back from a closing one.
    private static func matchBackwards(_ units: [UInt16], from closeIndex: Int,
                                       open: UInt16, close: UInt16) -> Int? {
        var depth = 0
        var index = closeIndex
        while index >= 0 {
            let c = units[index]
            if c == close { depth += 1 }
            if c == open {
                depth -= 1
                if depth == 0 { return index }
            }
            index -= 1
        }
        return nil
    }
}
