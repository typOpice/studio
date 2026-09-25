import Foundation
import Combine

/// Output window for scripts: `System.print`, `Runtime.log` and VM errors.
final class ScriptConsole: ObservableObject {
    enum Kind { case info, output, warning, error }

    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let kind: Kind
    }

    @Published private(set) var lines: [Line] = []
    private var pending: [Line] = []
    private let limit = 400
    /// Told of every line as it's written, before the buffering — the play session
    /// hands them to LogService.
    var onAppend: ((Line) -> Void)?

    func info(_ text: String) { append(Line(text: text, kind: .info)) }
    func output(_ text: String) { append(Line(text: text, kind: .output)) }
    func warning(_ text: String) { append(Line(text: text, kind: .warning)) }
    func error(_ text: String) { append(Line(text: text, kind: .error)) }

    var errorCount: Int { lines.filter { $0.kind == .error }.count }

    func clear() {
        pending = []
        lines = []
    }

    /// Buffered so a script printing every frame cannot thrash SwiftUI.
    private func append(_ line: Line) {
        onAppend?(line)
        pending.append(line)
        if pending.count == 1 {
            DispatchQueue.main.async { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending = []
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
}

/// Where a console line points: a script, by name, and a line in it. Errors read
/// `Name:12: message` from Luau (and `Name:12 function f` in its stack frames), and
/// `Name:12 — message` or `in Name:12` from Wren.
struct ConsoleLocation: Equatable {
    let scriptName: String
    let line: Int

    static func find(in text: String) -> ConsoleLocation? {
        var body = Substring(text).drop { $0 == " " || $0 == "\t" }
        if body.hasPrefix("in ") { body = body.dropFirst(3) }
        // The name runs to the first colon with a line number after it — a name may
        // itself hold a colon — and the number ends at a colon, a space or the end.
        var from = body.startIndex
        while let colon = body[from...].firstIndex(of: ":") {
            let rest = body[body.index(after: colon)...]
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            let after = rest.dropFirst(digits.count).first
            if !digits.isEmpty, after == nil || after == ":" || after == " ", let line = Int(digits) {
                var name = String(body[..<colon]).trimmingCharacters(in: .whitespaces)
                // Wren tells scripts that share a name apart as `Name#2`.
                if let hash = name.lastIndex(of: "#"), !name[name.index(after: hash)...].isEmpty,
                   name[name.index(after: hash)...].allSatisfy(\.isNumber) {
                    name = String(name[..<hash])
                }
                return name.isEmpty || line < 1 ? nil : ConsoleLocation(scriptName: name, line: line)
            }
            from = body.index(after: colon)
        }
        return nil
    }
}
