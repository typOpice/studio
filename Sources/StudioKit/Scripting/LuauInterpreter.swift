import Foundation
import CLuau

/// A value crossing the boundary between Swift and either scripting VM.
/// Values crossing the bridge — and, forwarded to another player, the network.
indirect enum ScriptValue: Codable, Equatable {
    case nothing
    case bool(Bool)
    case number(Double)
    case string(String)
    case list([ScriptValue])

    var asDouble: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    var asFloat: Float? { asDouble.map(Float.init) }

    var asString: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var asBool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var asList: [ScriptValue]? {
        if case .list(let l) = self { return l }
        return nil
    }

    var isNothing: Bool {
        if case .nothing = self { return true }
        return false
    }

    /// Three numbers, as used for positions, sizes and colours.
    var asTriple: (Float, Float, Float)? {
        guard let list = asList, list.count >= 3,
              let x = list[0].asFloat, let y = list[1].asFloat, let z = list[2].asFloat
        else { return nil }
        return (x, y, z)
    }

    static func triple(_ x: Float, _ y: Float, _ z: Float) -> ScriptValue {
        .list([.number(Double(x)), .number(Double(y)), .number(Double(z))])
    }
}

/// Drives an embedded Luau VM.
///
/// The whole host API funnels through one registered function, `__studio_invoke`,
/// which keeps the C surface tiny while the readable API — `workspace`, `Vector3`,
/// `part.Position` — is written in Luau on top of it.
final class LuauInterpreter {

    typealias Handler = (String, [ScriptValue]) -> ScriptValue

    private var vm: OpaquePointer?

    /// Called for every `__studio_invoke`.
    var handler: Handler = { _, _ in .nothing }

    /// How long a single script or callback may run before it is stopped.
    var timeout: Double = 2.0 {
        didSet {
            if let vm { studio_lua_set_timeout(vm, timeout) }
        }
    }

    init?() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = studio_lua_new(context, { context, vm, argc in
            guard let context, let vm else { return 0 }
            let interpreter = Unmanaged<LuauInterpreter>.fromOpaque(context).takeUnretainedValue()
            return interpreter.dispatch(vm: vm, argumentCount: argc)
        }) else { return nil }
        vm = created
        studio_lua_set_timeout(created, timeout)
    }

    deinit {
        if let vm { studio_lua_free(vm) }
    }

    // MARK: - The debugger (ScriptDebugger drives it)

    /// Reached a breakpoint at a line: every script is frozen until this returns.
    var onPause: ((Int) -> Void)?
    /// A chunk loaded into an environment ("" for the shared globals); keep it with `keepChunk`.
    var onLoaded: ((String) -> Void)?

    func attachDebugger() {
        guard let vm else { return }
        studio_lua_set_debugger(vm, { context, _, line in
            guard let context else { return }
            Unmanaged<LuauInterpreter>.fromOpaque(context).takeUnretainedValue().onPause?(Int(line))
        }, { context, _, environment in
            guard let context else { return }
            let name = environment.map { String(cString: $0) } ?? ""
            Unmanaged<LuauInterpreter>.fromOpaque(context).takeUnretainedValue().onLoaded?(name)
        })
    }

    /// Keeps the chunk just loaded (only from `onLoaded`) under a key: a script's id.
    func keepChunk(key: String) {
        guard let vm else { return }
        studio_lua_keep_chunk(vm, key)
    }

    /// Sets or clears a breakpoint in every chunk kept under the key; the line it landed on.
    @discardableResult
    func setBreakpoint(key: String, line: Int, enabled: Bool) -> Int {
        guard let vm else { return -1 }
        return Int(studio_lua_set_breakpoint(vm, key, Int32(line), enabled ? 1 : 0))
    }

    func breakEverywhere(_ enabled: Bool) {
        guard let vm else { return }
        studio_lua_break_everywhere(vm, enabled ? 1 : 0)
    }

    /// While paused: the thread that stopped, and how deep it is.
    var pausedThread: UnsafeRawPointer? { vm.flatMap { studio_lua_debug_thread($0) } }
    var pausedDepth: Int { vm.map { Int(studio_lua_debug_depth($0)) } ?? 0 }

    struct DebugFrame {
        var environment: String
        var function: String
        var line: Int
    }

    func frame(_ level: Int) -> DebugFrame? {
        guard let vm else { return nil }
        var environment: UnsafePointer<CChar>?, function: UnsafePointer<CChar>?
        var line: Int32 = 0
        guard studio_lua_debug_frame(vm, Int32(level), &environment, &function, &line) != 0 else { return nil }
        return DebugFrame(environment: environment.map { String(cString: $0) } ?? "",
                          function: function.map { String(cString: $0) } ?? "", line: Int(line))
    }

    struct DebugVariable: Equatable {
        var name: String
        var kind: String
        var type: String
        var value: String
        /// How to reach it in an expression — a name, or after its table's: `.key`,
        /// `["key"]`, `[1]`; "" when it can't be.
        var path = ""
    }

    func variables(at level: Int) -> [DebugVariable] {
        guard let vm else { return [] }
        return debugVariables(count: studio_lua_debug_variables(vm, Int32(level)))
    }

    /// The entries (up to `most`) of the table an expression comes to in a frame, while
    /// paused; nil if it isn't a table.
    func fields(of expression: String, at level: Int, most: Int = 200) -> [DebugVariable]? {
        guard let vm else { return nil }
        let count = studio_lua_debug_fields(vm, Int32(level), expression, Int32(most))
        return count < 0 ? nil : debugVariables(count: count)
    }

    private func debugVariables(count: Int32) -> [DebugVariable] {
        guard let vm else { return [] }
        return (0..<count).map { index in
            var name: UnsafePointer<CChar>?, kind: UnsafePointer<CChar>?, type: UnsafePointer<CChar>?,
                value: UnsafePointer<CChar>?
            studio_lua_debug_variable(vm, index, &name, &kind, &type, &value)
            func text(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
            return DebugVariable(name: text(name), kind: text(kind), type: text(type), value: text(value),
                                 path: text(studio_lua_debug_variable_path(vm, index)))
        }
    }

    /// An expression, worked out in a frame while paused: its locals and upvalues first,
    /// then the script's globals.
    struct Evaluation: Equatable {
        var type = ""
        var value = ""
        /// Why there's no value (it wouldn't compile, or failed); nil when there is one.
        var error: String?
        var truthy = false
    }

    func evaluate(_ expression: String, at level: Int) -> Evaluation {
        evaluation(of: expression, at: level, studio_lua_debug_evaluate)
    }

    /// A logpoint's message: `"health", health` comes to "health 50", as print writes it.
    func logMessage(_ expression: String, at level: Int) -> Evaluation {
        evaluation(of: expression, at: level, studio_lua_debug_log)
    }

    private func evaluation(of expression: String, at level: Int,
                            _ work: (OpaquePointer, Int32, UnsafePointer<CChar>) -> Int32) -> Evaluation {
        guard let vm else { return Evaluation(error: "not running") }
        let succeeded = work(vm, Int32(level), expression) != 0
        var type: UnsafePointer<CChar>?, value: UnsafePointer<CChar>?, error: UnsafePointer<CChar>?
        var truthy: Int32 = 0
        studio_lua_debug_evaluation(vm, &type, &value, &error, &truthy)
        func text(_ pointer: UnsafePointer<CChar>?) -> String { pointer.map { String(cString: $0) } ?? "" }
        // Without the expression's own chunk name ("watch:1: attempt to…").
        let reason = text(error).replacingOccurrences(of: #"^watch:\d+: "#, with: "", options: .regularExpression)
        return Evaluation(type: text(type), value: text(value), error: succeeded ? nil : reason,
                          truthy: succeeded && truthy != 0)
    }

    // MARK: - Running code

    /// Freezes the standard library so scripts cannot redefine it for each other.
    func sandbox() {
        guard let vm else { return }
        studio_lua_sandbox(vm)
    }

    /// Runs a chunk. `environment` names a globals table created with
    /// `makeEnvironment`, which is how each script gets its own `script` without a
    /// prelude — so reported line numbers are the user's own, with no offset.
    @discardableResult
    func run(name: String, source: String, environment: String? = nil) -> Bool {
        guard let vm else { return false }
        if let environment {
            return studio_lua_run(vm, name, source, environment) == 0
        }
        return studio_lua_run(vm, name, source, nil) == 0
    }

    /// Compiles a chunk and runs it inside a coroutine via `__studio_spawn`, so the
    /// script may call `task.wait` at the top level.
    @discardableResult
    func spawn(name: String, source: String, environment: String) -> Bool {
        guard let vm else { return false }
        return studio_lua_spawn(vm, name, source, environment) == 0
    }

    @discardableResult
    func callGlobal(_ name: String, argument: Double) -> Bool {
        guard let vm else { return false }
        return studio_lua_call_number(vm, name, argument) == 0
    }

    var lastError: String {
        guard let vm, let message = studio_lua_last_error(vm) else { return "" }
        return String(cString: message)
    }

    var memoryUsed: Int {
        guard let vm else { return 0 }
        return studio_lua_memory(vm)
    }

    func makeEnvironment(_ name: String) {
        guard let vm else { return }
        studio_lua_make_environment(vm, name)
    }

    func dropEnvironment(_ name: String) {
        guard let vm else { return }
        studio_lua_drop_environment(vm, name)
    }

    // MARK: - Marshalling

    private func read(_ vm: OpaquePointer, at index: Int32) -> ScriptValue {
        switch studio_lua_type(vm, index) {
        case Int32(STUDIO_LUA_BOOLEAN):
            return .bool(studio_lua_to_boolean(vm, index) != 0)
        case Int32(STUDIO_LUA_NUMBER):
            return .number(studio_lua_to_number(vm, index))
        case Int32(STUDIO_LUA_STRING):
            guard let text = studio_lua_to_string(vm, index) else { return .string("") }
            return .string(String(cString: text))
        case Int32(STUDIO_LUA_TABLE):
            let count = studio_lua_length(vm, index)
            guard count > 0 else { return .list([]) }
            var values: [ScriptValue] = []
            values.reserveCapacity(Int(count))
            for position in 1...count {
                studio_lua_get_index(vm, index, position)
                values.append(read(vm, at: studio_lua_top(vm)))
                studio_lua_pop(vm, 1)
            }
            return .list(values)
        default:
            return .nothing
        }
    }

    private func push(_ vm: OpaquePointer, _ value: ScriptValue) {
        switch value {
        case .nothing:
            studio_lua_push_nil(vm)
        case .bool(let b):
            studio_lua_push_boolean(vm, b ? 1 : 0)
        case .number(let d):
            studio_lua_push_number(vm, d)
        case .string(let s):
            studio_lua_push_string(vm, s)
        case .list(let items):
            studio_lua_push_table(vm, Int32(items.count))
            for (offset, item) in items.enumerated() {
                push(vm, item)
                studio_lua_set_index(vm, Int32(offset + 1))
            }
        }
    }

    fileprivate func dispatch(vm: OpaquePointer, argumentCount: Int32) -> Int32 {
        guard argumentCount >= 1, let namePointer = studio_lua_to_string(vm, 1) else {
            studio_lua_push_nil(vm)
            return 1
        }
        let name = String(cString: namePointer)

        var arguments: [ScriptValue] = []
        if argumentCount > 1 {
            arguments.reserveCapacity(Int(argumentCount - 1))
            for index in 2...argumentCount {
                arguments.append(read(vm, at: index))
            }
        }

        push(vm, handler(name, arguments))
        return 1
    }
}
