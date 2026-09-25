import Foundation

/// Suggestions for the shader editor.
///
/// Deliberately simpler than the Wren side: MSL has no dynamic receivers to resolve,
/// so this offers what is in scope — the injected inputs, the shader's own parameters,
/// the built-in maths functions and the type names — plus vector swizzles after a dot.
enum MetalCompletion {

    private static let swizzles = ["x", "y", "z", "w", "xy", "xyz", "xyzw",
                                   "r", "g", "b", "a", "rgb", "rgba"]

    static func items(in text: String, caret: Int, parameters: [String] = [],
                      kind: ShaderKind = .surface) -> [CompletionItem] {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        guard !MetalSyntax.isInCommentOrString(offset: caret, in: text) else { return [] }

        let range = WrenCompletion.partialWordRange(in: text, caret: caret)
        let prefix = String(decoding: units[range.location..<(range.location + range.length)],
                            as: UTF16.self).lowercased()

        var candidates: [CompletionItem] = []

        // After a dot, the only sensible completions are vector components.
        if range.location > 0, units[range.location - 1] == UInt16(UInt8(ascii: ".")) {
            candidates = swizzles.map {
                CompletionItem(label: $0, insert: $0, detail: "component", kind: .property, returns: nil)
            }
        } else {
            for input in ShaderSource.inputs(for: kind) {
                // `sample(uv)` is a function, not a value.
                if input.name.hasSuffix(")") {
                    candidates.append(CompletionItem(label: input.name, insert: "sample(",
                                                     detail: input.type, kind: .method, returns: nil))
                } else {
                    candidates.append(CompletionItem(label: input.name, insert: input.name,
                                                     detail: input.type, kind: .property, returns: nil))
                }
            }
            for name in parameters where ShaderSource.isValidParameterName(name) {
                candidates.append(CompletionItem(label: name, insert: name,
                                                 detail: "parameter", kind: .variable, returns: nil))
            }
            for function in MetalSyntax.builtins {
                candidates.append(CompletionItem(label: "\(function)()", insert: "\(function)(",
                                                 detail: "function", kind: .method, returns: nil))
            }
            for type in MetalSyntax.types.sorted() {
                candidates.append(CompletionItem(label: type, insert: type,
                                                 detail: "type", kind: .type, returns: nil))
            }
            for keyword in MetalSyntax.keywords.sorted() {
                candidates.append(CompletionItem(label: keyword, insert: keyword,
                                                 detail: "keyword", kind: .keyword, returns: nil))
            }
        }

        var seen: Set<String> = []
        let matched = candidates.filter { item in
            guard prefix.isEmpty || item.label.lowercased().hasPrefix(prefix) else { return false }
            return seen.insert(item.label).inserted
        }
        return Array(matched.sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }.prefix(60))
    }
}
