import Foundation
import CWren

enum WrenOutput {
    case print(String)
    case error(String)
}

/// Thin Swift wrapper around an embedded Wren VM — the secondary language.
///
/// Like the Luau side, the whole host API funnels through one foreign method,
/// `Studio.invoke_`, overloaded by arity; the readable API — `Workspace`, `Vec3` —
/// is written in Wren on top of it (`WrenModules.swift`).
///
/// Unlike Luau, Wren has no interrupt hook, so there is no watchdog: an endless
/// loop in a Wren script hangs the app.
final class WrenInterpreter {

    typealias Handler = (String, [ScriptValue]) -> ScriptValue

    private var vm: OpaquePointer?
    private var tickHandle: OpaquePointer?
    private var runtimeClassHandle: OpaquePointer?

    /// Called for every `Studio.invoke_`.
    var handler: Handler = { _, _ in .nothing }
    /// Receives `System.print` output and VM errors.
    var onOutput: (WrenOutput) -> Void = { _ in }
    /// Supplies source for `import "name"`.
    var moduleLoader: (String) -> String? = { _ in nil }

    private(set) var lastErrors: [String] = []

    /// Lines the host prepends to user source, subtracted from reported line numbers.
    var lineOffset = 0

    init() {
        var config = WrenConfiguration()
        wrenInitConfiguration(&config)
        config.writeFn = { vm, text in
            guard let interpreter = WrenInterpreter.from(vm), let text else { return }
            let string = String(cString: text)
            // Wren emits the trailing newline as its own write.
            if string != "\n" {
                interpreter.onOutput(.print(string.hasSuffix("\n") ? String(string.dropLast()) : string))
            }
        }
        config.errorFn = { vm, type, module, line, message in
            guard let interpreter = WrenInterpreter.from(vm) else { return }
            let moduleName = module.map { String(cString: $0) } ?? "?"
            let text = message.map { String(cString: $0) } ?? ""
            let formatted: String
            switch type {
            case WREN_ERROR_COMPILE:
                formatted = "\(moduleName):\(interpreter.reportedLine(line)) — \(text)"
            case WREN_ERROR_STACK_TRACE:
                formatted = "    in \(moduleName):\(interpreter.reportedLine(line))"
            default:
                formatted = text
            }
            interpreter.lastErrors.append(formatted)
            interpreter.onOutput(.error(formatted))
        }
        config.bindForeignMethodFn = { _, _, className, isStatic, signature in
            guard let className, let signature, isStatic,
                  String(cString: className) == "Studio" else { return nil }
            switch String(cString: signature) {
            case "invoke_(_)": return studioInvoke1
            case "invoke_(_,_)": return studioInvoke2
            case "invoke_(_,_,_)": return studioInvoke3
            case "invoke_(_,_,_,_)": return studioInvoke4
            case "invoke_(_,_,_,_,_)": return studioInvoke5
            default: return nil
            }
        }
        config.loadModuleFn = { vm, name in
            var result = WrenLoadModuleResult()
            guard let interpreter = WrenInterpreter.from(vm), let name,
                  let source = interpreter.moduleLoader(String(cString: name))
            else { return result }
            result.source = UnsafePointer(strdup(source))
            result.onComplete = { _, _, completed in
                if let source = completed.source {
                    free(UnsafeMutableRawPointer(mutating: source))
                }
            }
            return result
        }

        vm = wrenNewVM(&config)
        if let vm {
            wrenSetUserData(vm, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    deinit {
        if let vm {
            if let tickHandle { wrenReleaseHandle(vm, tickHandle) }
            if let runtimeClassHandle { wrenReleaseHandle(vm, runtimeClassHandle) }
            wrenFreeVM(vm)
        }
    }

    fileprivate static func from(_ vm: OpaquePointer?) -> WrenInterpreter? {
        guard let vm, let data = wrenGetUserData(vm) else { return nil }
        return Unmanaged<WrenInterpreter>.fromOpaque(data).takeUnretainedValue()
    }

    private func reportedLine(_ line: Int32) -> Int {
        max(1, Int(line) - lineOffset)
    }

    // MARK: - Running code

    @discardableResult
    func interpret(module: String, source: String) -> Bool {
        guard let vm else { return false }
        lastErrors = []
        return wrenInterpret(vm, module, source) == WREN_RESULT_SUCCESS
    }

    /// Calls `Runtime.tick_(dt)` in the studio module, if it has been loaded.
    @discardableResult
    func tick(dt: Double) -> Bool {
        guard let vm else { return false }
        if runtimeClassHandle == nil {
            guard wrenHasModule(vm, "studio"), wrenHasVariable(vm, "studio", "Runtime") else { return true }
            wrenEnsureSlots(vm, 1)
            wrenGetVariable(vm, "studio", "Runtime", 0)
            runtimeClassHandle = wrenGetSlotHandle(vm, 0)
            tickHandle = wrenMakeCallHandle(vm, "tick_(_)")
        }
        guard let runtimeClassHandle, let tickHandle else { return true }

        lastErrors = []
        wrenEnsureSlots(vm, 2)
        wrenSetSlotHandle(vm, 0, runtimeClassHandle)
        wrenSetSlotDouble(vm, 1, dt)
        return wrenCall(vm, tickHandle) == WREN_RESULT_SUCCESS
    }

    // MARK: - Slot marshalling

    fileprivate func readSlot(_ vm: OpaquePointer, _ slot: Int32) -> ScriptValue {
        switch wrenGetSlotType(vm, slot) {
        case WREN_TYPE_BOOL:
            return .bool(wrenGetSlotBool(vm, slot))
        case WREN_TYPE_NUM:
            return .number(wrenGetSlotDouble(vm, slot))
        case WREN_TYPE_STRING:
            return .string(wrenGetSlotString(vm, slot).map { String(cString: $0) } ?? "")
        case WREN_TYPE_LIST:
            let count = wrenGetListCount(vm, slot)
            guard count > 0 else { return .list([]) }
            let scratch = wrenGetSlotCount(vm)
            wrenEnsureSlots(vm, scratch + 1)
            var values: [ScriptValue] = []
            values.reserveCapacity(Int(count))
            for index in 0..<count {
                wrenGetListElement(vm, slot, index, scratch)
                values.append(readSlot(vm, scratch))
            }
            return .list(values)
        default:
            return .nothing
        }
    }

    fileprivate func writeSlot(_ vm: OpaquePointer, _ slot: Int32, _ value: ScriptValue) {
        switch value {
        case .nothing:
            wrenSetSlotNull(vm, slot)
        case .bool(let b):
            wrenSetSlotBool(vm, slot, b)
        case .number(let d):
            wrenSetSlotDouble(vm, slot, d)
        case .string(let s):
            wrenSetSlotString(vm, slot, s)
        case .list(let items):
            wrenSetSlotNewList(vm, slot)
            let scratch = slot + 1
            wrenEnsureSlots(vm, scratch + 1)
            for item in items {
                writeSlot(vm, scratch, item)
                wrenInsertInList(vm, slot, -1, scratch)
            }
        }
    }

    fileprivate func dispatch(_ vm: OpaquePointer, extraArguments: Int32) {
        guard let namePointer = wrenGetSlotString(vm, 1) else {
            wrenSetSlotNull(vm, 0)
            return
        }
        let name = String(cString: namePointer)
        var arguments: [ScriptValue] = []
        arguments.reserveCapacity(Int(extraArguments))
        for slot in 0..<extraArguments {
            arguments.append(readSlot(vm, slot + 2))
        }
        writeSlot(vm, 0, handler(name, arguments))
    }
}

// MARK: - C trampolines

private func invoke(_ vm: OpaquePointer?, _ extraArguments: Int32) {
    guard let vm, let interpreter = WrenInterpreter.from(vm) else { return }
    interpreter.dispatch(vm, extraArguments: extraArguments)
}

private let studioInvoke1: WrenForeignMethodFn = { vm in invoke(vm, 0) }
private let studioInvoke2: WrenForeignMethodFn = { vm in invoke(vm, 1) }
private let studioInvoke3: WrenForeignMethodFn = { vm in invoke(vm, 2) }
private let studioInvoke4: WrenForeignMethodFn = { vm in invoke(vm, 3) }
private let studioInvoke5: WrenForeignMethodFn = { vm in invoke(vm, 4) }
