import Foundation

extension ScriptRuntime {
    func solidCall(_ arguments: [ScriptValue]) -> ScriptValue {
        func failure(_ message: String) -> ScriptValue { .list([.bool(false), .string(message)]) }
        guard runsSceneScripts, arguments.count >= 3, arguments[2].asBool != true else {
            return failure("Solid operations may only run in a server Script.")
        }
        guard case .list(let values) = arguments[0], values.count >= 2,
              let operation = arguments[1].asString else { return failure("An array of BaseParts is required.") }
        let ids = values.compactMap { partID($0) }
        guard ids.count == values.count else { return failure("A solid operand has been destroyed.") }
        do {
            let cutters = operation == "subtract" ? Set(ids.dropFirst()) : Set<UUID>()
            let id = try model.makeUnion(ids, subtract: cutters, undoable: false, consume: false)
            return .list([.bool(true), .string(id.uuidString)])
        } catch { return failure(error.localizedDescription) }
    }
}
