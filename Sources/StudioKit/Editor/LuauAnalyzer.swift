import Foundation
import CLuau

struct LuauDiagnostic: Equatable, Identifiable {
    var node: Int
    var line: Int
    var column: Int
    var endLine: Int
    var endColumn: Int
    var message: String
    var id: String { "\(node):\(line):\(column):\(message)" }

    /// Luau columns are UTF-8 byte offsets; NSTextView uses UTF-16 code units.
    func range(in source: String) -> NSRange {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        func offset(_ line: Int, _ column: Int) -> Int {
            let index = min(max(line - 1, 0), max(lines.count - 1, 0))
            var result = lines.prefix(index).reduce(0) { $0 + $1.utf16.count + 1 }
            guard lines.indices.contains(index) else { return result }
            let bytes = lines[index].utf8
            let count = min(max(column, 0), bytes.count)
            let prefix = String(decoding: bytes.prefix(count), as: UTF8.self)
            result += prefix.utf16.count
            return min(result, source.utf16.count)
        }
        let start = offset(line, column), end = offset(endLine, endColumn)
        return NSRange(location: start, length: max(0, end - start))
    }
}

struct LuauAnalysisSnapshot: Equatable {
    var scene: LuauScene
    var target: Int
    var source: String
    var sceneID: UUID?

    init(source: String, scene: LuauScene = LuauScene(), sceneID: UUID? = nil) {
        var graph = scene
        if graph.script == nil {
            graph.script = graph.add(.init(name: "Script", className: "Script", parent: graph.places["ServerScriptService"]))
        }
        self.target = graph.script!
        graph.nodesForAnalysis(source: source, at: target)
        self.scene = graph
        self.source = source
        self.sceneID = sceneID
    }
}

private final class AnalysisCollector { var diagnostics: [LuauDiagnostic] = [] }

enum LuauAnalyzer {
    static let maximumSourceBytes = 256 * 1024
    static let maximumGraphBytes = 1024 * 1024
    static func analyze(source: String) -> [LuauDiagnostic] { analyze(LuauAnalysisSnapshot(source: source)) }

    static func analyze(_ snapshot: LuauAnalysisSnapshot) -> [LuauDiagnostic] {
        let nodes = snapshot.scene.nodes
        guard nodes.count <= 4096, snapshot.scene.modules.count <= 128,
              nodes.allSatisfy({ ($0.source?.utf8.count ?? 0) <= maximumSourceBytes }),
              nodes.reduce(0, { $0 + ($1.source?.utf8.count ?? 0) }) <= maximumGraphBytes else {
            return [.init(node: snapshot.target, line: 1, column: 0, endLine: 1, endColumn: 1,
                          message: "Type analysis exceeds the source or module complexity budget (256 KB per script, 1 MB or 128 modules per scene).")]
        }
        // Own every UTF-8 buffer for the entire synchronous native call.
        var strings: [UnsafeMutablePointer<CChar>] = []
        func keep(_ value: String) -> UnsafePointer<CChar> {
            let pointer = strdup(value)!
            strings.append(pointer)
            return UnsafePointer(pointer)
        }
        defer { strings.forEach { free($0) } }
        let native = nodes.map { node in
            StudioAnalysisNode(name: keep(node.name), source: node.source.map(keep),
                               parent: Int32(node.parent ?? -1), is_module: node.className == "ModuleScript" ? 1 : 0)
        }
        let types: [UnsafePointer<CChar>?] = nodes.indices.map { keep("SceneNode\($0)") }
        let definitions = keep(LuauTypeDefinitions.source(scene: snapshot.scene))
        let collector = AnalysisCollector()
        native.withUnsafeBufferPointer { nodeBuffer in
            types.withUnsafeBufferPointer { typeBuffer in
                studio_luau_analyze(nodeBuffer.baseAddress, nodeBuffer.count, Int32(snapshot.target), definitions,
                                    typeBuffer.baseAddress, { context, node, line, column, endLine, endColumn, message in
                    guard let context, let message else { return }
                    let result = Unmanaged<AnalysisCollector>.fromOpaque(context).takeUnretainedValue()
                    result.diagnostics.append(.init(node: Int(node), line: Int(line) + 1, column: Int(column),
                                                    endLine: Int(endLine) + 1, endColumn: Int(endColumn),
                                                    message: String(cString: message)))
                }, Unmanaged.passUnretained(collector).toOpaque())
            }
        }
        return collector.diagnostics
    }
}
