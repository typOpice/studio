/// The library every script sees: a Roblox-flavoured object model over the host.
///
/// It runs once in the shared globals, before the VM is sandboxed. Sandboxing
/// freezes every table reachable from a global, so anything that has to change at
/// run time — the scheduler, event connections, object registries — lives in
/// locals, and the singletons that need assignment semantics (`Screen.Shader = …`)
/// are userdata from `newproxy`, which sandboxing leaves alone.
///
/// Values that Roblox models as userdata (`Vector3`, `Color3`, instances) are tables
/// here, tagged in a weak table so the overridden `typeof` reports "Vector3" and
/// friends exactly as Roblox does.
let studioLibrarySource: String = studioLibraryTemplate.replacingOccurrences(
    of: "__KEYCODE_NAMES__",
    with: KeyCodes.allNames.map { "\"\($0)\"" }.joined(separator: ", "))

/// The library's Luau, in the order it runs. Each part is in its own file under
/// `LuauLibrary/`, by topic; they are joined into one chunk, so a `local` declared in
/// one part is in scope in every part after it. Add to the part that fits, and keep
/// anything a later part uses above it.
enum LuauLibrary {
    static let inOrder = [
        core,
        values,
        shaderValues,
        cframe,
        parts,
        modelsLightsJoints,
        services,
        scheduler,
        gui,
        player,
        animations,
        tools,
        hostEvents,
        extras,
        data,
        entryPoints
    ]
}

private let studioLibraryTemplate = LuauLibrary.inOrder.joined(separator: "\n")
